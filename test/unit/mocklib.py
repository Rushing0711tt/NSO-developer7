from __future__ import print_function

import sys
from contextlib import contextmanager
import functools
from pyfakefs import fake_filesystem_unittest as ffs
if sys.version_info >= (3, 3):
    import unittest.mock as mock
else:
    import mock

patch = mock.patch
Mock = mock.Mock


class MaapiMock(Mock):
    def __enter__(self):
        return self

    def __exit__(*ignore):
        pass


@contextmanager
def nest_mgrs(mgrs):
    if mgrs == []:
        yield []
    else:
        with mgrs[0] as v:
            with nest_mgrs(mgrs[1:]) as vs:
                vs.append(v)
                yield vs


class XtestPatch(object):
    """Mimic `unittest.mock.patch' behavior to make pytest ignore test
    function arguments."""

    def __init__(self, mock_gens):
        self.attribute_name = None
        self.new = mock.DEFAULT
        self.mock_gens = mock_gens

    def __call__(self, fn):
        if hasattr(fn, 'patchings'):
            raise RuntimeError('cannot combine XtestPatch with mock.patch')
        fn.patchings = [self]

        @functools.wraps(fn)
        def wrapper(*args):
            with nest_mgrs([gen() for gen in self.mock_gens]) as mocks:
                for mock_inst in mocks:
                    setattr(self, mock_inst.name, mock_inst)
                args = list(args)
                args.append(self)
                fn(*args)
        return wrapper


def xtest_patch(*patch_args):
    if len(patch_args) == 1 and callable(patch_args[0]):
        return XtestPatch((system_mock, ncs_mock))(patch_args[0])
    return XtestPatch(patch_args)


class XtestMock(object):
    def __init__(self, name):
        self.name = name


XMNR_DIRECTORY = 'test_xmnr_dir'
DRNED_DIRECTORY = 'drned_dir'
DEVICE_NAME = 'mock-device'
XMNR_INSTALL = 'xmnr-install'


@contextmanager
def ncs_mock():
    device = Mock(device_type=Mock(ne_type='netconf', netconf='netconf'))
    rootmock = Mock(devices=Mock(device={DEVICE_NAME: device}),
                    packages=Mock(package={'drned-xmnr': Mock(directory=XMNR_INSTALL)}),
                    drned_xmnr=Mock(xmnr_directory=XMNR_DIRECTORY,
                                    drned_directory=DRNED_DIRECTORY,
                                    xmnr_log_file=None))
    ncs_items = ['_ncs.stream_connect', '_ncs.dp.action_set_timeout']
    with patch('ncs.maapi.Maapi', return_value=MaapiMock()) as maapi:
        with patch('ncs.maagic.get_root', return_value=rootmock):
            with nest_mgrs([patch(ncs_item) for ncs_item in ncs_items]) as ncs_patches:
                mock_inst = XtestMock('ncs')
                items = [it.split('.')[-1] for it in ncs_items]
                mock_inst.data = dict(maapi=maapi,
                                      root=rootmock,
                                      device=device,
                                      ncs=dict(zip(items, reversed(ncs_patches))))
                yield mock_inst


class FileData(object):
    def __init__(self, name, data=None):
        self.name = name
        self.data = data

    def read(self):
        if self.data is None:
            raise RuntimeError('Cannot read from {}'.format(self.name))
        return self.data

    def write(self, data):
        if self.data is None:
            self.data = b''
        self.data += data

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass


class StreamData(object):
    """Auxiliary class for mocking anything that provides streamed data."""
    def __init__(self, data, chunk):
        if data == []:
            self.data = []
        else:
            self.data = [data[i*chunk:(i+1)*chunk]
                         for i in range(0, (len(data)+chunk-1)//chunk)]

    def __iter__(self):
        return self

    def next(self):
        if self.finished():
            raise StopIteration()
        return self.data.pop(0)

    def finished(self):
        return self.data == []


class SystemMock(XtestMock):
    def __init__(self, ff_patcher, patches):
        super(SystemMock, self).__init__('system')
        self.patches = patches
        self.ff_patcher = ff_patcher
        socket = patches['socket']['socket']
        socket.return_value = mock.Mock(recv=Mock(side_effect=self.get_socket_data))
        self.socket_data('')

    def socket_data(self, data, chunk=10):
        self.socket_data_iter = self.chunk_data(data, chunk)

    def chunk_data(self, data, chunk):
        return (data[i*chunk:(i+1)*chunk] for i in range(0, (len(data)+chunk-1)//chunk))

    def get_socket_data(self, *args):
        try:
            return next(self.socket_data_iter)
        except StopIteration:
            return ''


@contextmanager
def system_mock():
    """Mock system-level functions.

    Functions from fcntl, pickle, select, socket,
    subprocess are mocked to avoid tests touching the system state.
    """
    calls = {'fcntl': ['fcntl'],
             'pickle': ['load', 'dump'],
             'select': ['select'],
             'socket': ['socket'],
             'subprocess': ['Popen']}

    @contextmanager
    def make_patch_group(name):
        with nest_mgrs([mock.patch('{}.{}'.format(name, item)) for item in calls[name]]) as mgrs:
            yield dict(zip(calls[name], reversed(mgrs)))

    with nest_mgrs([make_patch_group(name) for name in calls]) as patchlist:
        with ffs.Patcher() as ff_patcher:
            # os.environ needs special care
            with mock.patch.dict('os.environ', {'NCS_DIR': 'tmp_ncs_dir'}):
                patches = dict(zip(calls.keys(), reversed(patchlist)))
                popen = patches['subprocess']['Popen']
                wait_mock = mock.Mock(return_value=0)
                popen.return_value = mock.Mock(wait=wait_mock)
                yield SystemMock(ff_patcher, patches)


def init_mocks():
    """Patch all necessary classes and functions.

    Some of PyAPI classes and functions need to be patched early on,
    before the modules using them are imported; this applies mostly to
    classes used as superclasses and decorator functions. These
    patchings remains active for the rest of the Python environment
    lifetime, the patchers' `stop' method is never called!
    """
    patch('ncs.application.Application', new_callable=lambda: mock.Mock).start()
    patch('ncs.dp.Action.action', side_effect=lambda fn: fn).start()
    patch('ncs.dp.Action.__init__', return_value=None).start()
