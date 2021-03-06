-module(ec_transform_server).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("econfd/include/econfd.hrl").
-include_lib("econfd/include/econfd_errors.hrl").
-include_lib("ec_transform/include/users.hrl").
-include("tailf-aaa.hrl").
-include("ietf-netconf-acm.hrl").

-record(state,
        {
          daemon     :: pid()
        }).

-define(AAA_USER, [user, users, authentication, [?aaa__ns_uri|aaa]]).
-define(AAA_GROUP, [group, groups, [?nacm__ns_uri|nacm]]).

-define(SERVER, ?MODULE).

-define(M_CONFD_PORT, 5010).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% call(Msg) ->
%%     gen_server:call(?SERVER, Msg, infinity).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
init([]) ->
    process_flag(trap_exit, true), % Triggers call to terminate/2

    Trans = #confd_trans_cbs{init   = fun init_transformation/1,
                             finish = fun stop_transformation/1},
    Data = #confd_data_cbs{get_elem = fun get_elem/2,
                           get_next = fun get_next/3,
                           set_elem = fun set_elem/3,
                           create   = fun create/2,
                           remove   = fun remove/2,
                           callpoint = ?users__callpointid_simple_aaa},

    Port = case os:getenv("CONFD_IPC_PORT") of
               false ->
                   ?CONFD_PORT;
               StrPort ->
                   list_to_integer(StrPort)
           end,
    {ok, Daemon} = econfd:init_daemon(users_aaa, ?CONFD_DEBUG, user,
                                      undefined, {127,0,0,1}, Port),
    ok = econfd:register_trans_cb(Daemon, Trans),
    ok = econfd:register_data_cb(Daemon, Data),
    ok = econfd:register_done(Daemon),

    log(info, "Server started.\n", []),

    {ok, #state{daemon=Daemon}}.

%%--------------------------------------------------------------------
handle_call(Req, _From, State) ->
    error_logger:error_msg("~p: Got unexpected call: ~p\n",
                           [?SERVER, Req]),
    Reply = error,
    {reply, Reply, State}.

%%--------------------------------------------------------------------
handle_cast(Msg, State) ->
    error_logger:error_msg("~p: Got unexpected cast: ~p\n",
                           [?SERVER, Msg]),
    {noreply, State}.

%%--------------------------------------------------------------------
handle_info(Info, State) ->
    error_logger:error_msg("~p: Got unexpected info: ~p\n",
                           [?SERVER, Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
terminate(Reason, _State) ->
    log(info, "Server stopped - ~p\n", [Reason]),
    ok.

%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% Transaction callbacks

init_transformation(Tctx) ->
    %% We need a separate maapi socket for each transaction,
    %% to avoid simultaneous use by control and worker socket
    %% callbacks (the daemon runs them in different processes).
    {ok, MaapiSock} = econfd_maapi:connect({127,0,0,1}, ?M_CONFD_PORT),
    ok = econfd_maapi:attach(MaapiSock, 0, Tctx),
    {ok, Tctx#confd_trans_ctx{opaque = MaapiSock}}.

stop_transformation(Tctx) ->
    econfd_maapi:close(Tctx#confd_trans_ctx.opaque),
    ok.


%% Data callbacks

get_elem(Tctx, [name, Key | _Tail]) ->
    maapi_get_elem(Tctx, [name, Key | ?AAA_USER]);
get_elem(Tctx, [password, Key | _Tail]) ->
    maapi_get_elem(Tctx, [password, Key | ?AAA_USER]);
get_elem(Tctx, [role, {?CONFD_BUF(User)} | _Tail]) ->
    NotMemberF = fun ({Group, _Role}) ->
                         not is_group_member(Tctx, User, Group)
                 end,
    GroupRoles = [{<<"admin">>, ?users_admin}, {<<"oper">>, ?users_oper}],
    case lists:dropwhile(NotMemberF, GroupRoles) of
        [{_Group, Role}|_] ->
            {ok, ?CONFD_ENUM_VALUE(Role)};
        _ ->
            {ok, not_found}
    end;
get_elem(_Tctx, [Tag | _Tail]) ->
    internal_error("unexpected get_elem tag ~p", [Tag]).

set_elem(Tctx, [password, Key | _Tail], Value) ->
    maapi_set_elem(Tctx, [password, Key | ?AAA_USER], Value);
set_elem(Tctx, [role, {?CONFD_BUF(User)} = Key | _Tail], Value) ->
    case Value of
        ?CONFD_ENUM_VALUE(?users_admin) ->
            ok([maapi_set_elem2(Tctx, [uid, Key | ?AAA_USER], <<"0">>),
                maapi_set_elem2(Tctx, [gid, Key | ?AAA_USER], <<"0">>),
                add_user_to_group(Tctx, User, <<"admin">>),
                del_user_from_group(Tctx, User, <<"oper">>)]);
        ?CONFD_ENUM_VALUE(?users_oper) ->
            ok([maapi_set_elem2(Tctx, [uid, Key | ?AAA_USER], <<"20">>),
                maapi_set_elem2(Tctx, [gid, Key | ?AAA_USER], <<"20">>),
                add_user_to_group(Tctx, User, <<"oper">>),
                del_user_from_group(Tctx, User, <<"admin">>)]);
        ?CONFD_ENUM_VALUE(Enum) ->
            internal_error("unexpected role enum ~p", [Enum])
    end;
set_elem(_Tctx, [Tag | _Tail], _Value) ->
    internal_error("unexpected set_elem tag ~p", [Tag]).

get_next(Tctx, _IKeypath, -1) ->
    MaapiCursor = maapi_init_cursor(Tctx, ?AAA_USER),
    maapi_get_next(MaapiCursor);
get_next(_Tctx, _IKeypath, MaapiCursor) ->
    maapi_get_next(MaapiCursor).

remove(Tctx,  [{?CONFD_BUF(User)} = Key | _Tail]) ->
    ok([maapi_delete(Tctx, [Key | ?AAA_USER]),
        del_user_from_group(Tctx, User, <<"oper">>),
        del_user_from_group(Tctx, User, <<"admin">>)]).

create(Tctx,  [{?CONFD_BUF(User)} = Key | _Tail]) ->
    ok([maapi_create(Tctx, [Key | ?AAA_USER]),
        maapi_set_elem2(Tctx, [homedir, Key | ?AAA_USER],
                        <<"/var/confd/homes/", User/binary>>),
        maapi_set_elem2(Tctx, [ssh_keydir, Key | ?AAA_USER],
                        <<"/var/confd/homes/", User/binary, "/.ssh">>)]).


%% Utility functions

ok([ok|Tail])     -> ok(Tail);
ok([Error|_Tail]) -> Error;
ok([])            -> ok.

add_user_to_group(Tctx, User, Group) ->
    IKeypath = group_members_path(Group),
    case maapi_get_elem(Tctx, IKeypath) of
        {ok, ?CONFD_LIST(Users)} when is_list(Users) ->
            ok;
        _ ->
            Users = []
    end,
    case lists:member(User, Users) of
        true ->
            ok;
        false ->
            maapi_set_elem(Tctx, IKeypath, ?CONFD_LIST([User|Users]))
    end.

del_user_from_group(Tctx, User, Group) ->
    IKeypath = group_members_path(Group),
    case maapi_get_elem(Tctx, IKeypath) of
        {ok, ?CONFD_LIST(Users)} when is_list(Users) ->
            ok;
        _ ->
            Users = []
    end,
    case lists:member(User, Users) of
        true ->
            maapi_set_elem(Tctx, IKeypath,
                           ?CONFD_LIST(lists:delete(User, Users)));
        false ->
            ok
    end.

is_group_member(Tctx, User, Group) ->
    case maapi_get_elem(Tctx, group_members_path(Group)) of
        {ok, ?CONFD_LIST(Users)} when is_list(Users) ->
            lists:member(User, Users);
        _ ->
            false
    end.

group_members_path(Group) ->
    ['user-name', {?CONFD_BUF(Group)} | ?AAA_GROUP].

maapi_get_elem(#confd_trans_ctx{opaque = MaapiSock, thandle = Thandle},
               IKeypath) ->
    case econfd_maapi:get_elem(MaapiSock, Thandle, IKeypath) of
        {ok, Value} ->
            {ok, Value};
        {error, {?CONFD_ERR_NOEXISTS, _}} ->
            {ok, not_found};
        {error, Error} ->
            internal_error("maapi get_elem returned error ~p", [Error])
    end.

maapi_set_elem(Tctx, IKeypath, Value) ->
    maapi_set(Tctx, set_elem, IKeypath, Value).

maapi_set_elem2(Tctx, IKeypath, Value) ->
    maapi_set(Tctx, set_elem2, IKeypath, Value).

maapi_set(#confd_trans_ctx{opaque = MaapiSock, thandle = Thandle},
          SetF, IKeypath, Value) ->
    case econfd_maapi:SetF(MaapiSock, Thandle, IKeypath, Value) of
        ok ->
            ok;
        {error, Error} ->
            internal_error("maapi ~p returned error ~p", [SetF, Error])
    end.

maapi_init_cursor(#confd_trans_ctx{opaque = MaapiSock, thandle = Thandle},
                  IKeypath) ->
    econfd_maapi:init_cursor(MaapiSock, Thandle, IKeypath).

maapi_get_next(Cursor) ->
    case econfd_maapi:get_next(Cursor) of
        done ->
            {ok, {false, undefined}};
        {ok, Key, NewCursor} ->
            {ok, {Key, NewCursor}};
        {error, Error} ->
            internal_error("maapi get_next returned error ~p", [Error])
    end.

maapi_delete(#confd_trans_ctx{opaque = MaapiSock, thandle = Thandle},
             IKeypath) ->
    case econfd_maapi:delete(MaapiSock, Thandle, IKeypath) of
        ok ->
            ok;
        {error, Error} ->
            internal_error("maapi delete returned error ~p", [Error])
    end.

maapi_create(#confd_trans_ctx{opaque = MaapiSock, thandle = Thandle},
             IKeypath) ->
    case econfd_maapi:create(MaapiSock, Thandle, IKeypath) of
        ok ->
            ok;
        {error, Error} ->
            internal_error("maapi create returned error ~p", [Error])
    end.

internal_error(Fmt, Args) ->
    Msg = io_lib:format(Fmt, Args),
    {error, #confd_error{code = application_internal,
                         str = iolist_to_binary(Msg)}}.

log(error, Format, Args) ->
    econfd:log(?CONFD_LEVEL_ERROR, "~p: " ++ Format, [?SERVER | Args]);
log(info, Format, Args) ->
    econfd:log(?CONFD_LEVEL_INFO,  "~p: " ++ Format, [?SERVER | Args]);
log(trace, Format, Args) ->
    econfd:log(?CONFD_LEVEL_TRACE, "~p: " ++ Format, [?SERVER | Args]).
