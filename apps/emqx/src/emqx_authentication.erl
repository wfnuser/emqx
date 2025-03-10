%%--------------------------------------------------------------------
%% Copyright (c) 2021 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% @doc Authenticator management API module.
%% Authentication is a core functionality of MQTT,
%% the 'emqx' APP provides APIs for other APPs to implement
%% the authentication callbacks.
-module(emqx_authentication).

-behaviour(gen_server).

-include("emqx.hrl").
-include("logger.hrl").

-include_lib("stdlib/include/ms_transform.hrl").

%% The authentication entrypoint.
-export([ authenticate/2
        ]).

%% Authenticator manager process start/stop
-export([ start_link/0
        , stop/0
        , get_providers/0
        ]).

%% Authenticator management APIs
-export([ initialize_authentication/2
        , register_provider/2
        , register_providers/1
        , deregister_provider/1
        , deregister_providers/1
        , create_chain/1
        , delete_chain/1
        , lookup_chain/1
        , list_chains/0
        , list_chain_names/0
        , create_authenticator/2
        , delete_authenticator/2
        , update_authenticator/3
        , lookup_authenticator/2
        , list_authenticators/1
        , move_authenticator/3
        ]).

%% APIs for observer built-in-database
-export([ import_users/3
        , add_user/3
        , delete_user/3
        , update_user/4
        , lookup_user/3
        , list_users/3
        ]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

%% utility functions
-export([ authenticator_id/1
        ]).

%% proxy callback
-export([ pre_config_update/2
        , post_config_update/4
        ]).

-export_type([ authenticator_id/0
             , position/0
             , chain_name/0
             ]).

-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

-define(CHAINS_TAB, emqx_authn_chains).

-define(VER_1, <<"1">>).
-define(VER_2, <<"2">>).

-type chain_name() :: atom().
-type authenticator_id() :: binary().
-type position() :: top | bottom | {before, authenticator_id()}.
-type authn_type() :: atom() | {atom(), atom()}.
-type provider() :: module().

-type chain() :: #{name := chain_name(),
                   authenticators := [authenticator()]}.

-type authenticator() :: #{id := authenticator_id(),
                           provider := provider(),
                           enable := boolean(),
                           state := map()}.

-type config() :: emqx_authentication_config:config().
-type state() :: #{atom() => term()}.
-type extra() :: #{is_superuser := boolean(),
                   atom() => term()}.
-type user_info() :: #{user_id := binary(),
                       atom() => term()}.

%% @doc check_config takes raw config from config file,
%% parse and validate it, and reutrn parsed result.
-callback check_config(config()) -> config().

-callback create(Config)
    -> {ok, State}
     | {error, term()}
    when Config::config(), State::state().

-callback update(Config, State)
    -> {ok, NewState}
     | {error, term()}
    when Config::config(), State::state(), NewState::state().

-callback authenticate(Credential, State)
    -> ignore
     | {ok, Extra}
     | {ok, Extra, AuthData}
     | {continue, AuthCache}
     | {continue, AuthData, AuthCache}
     | {error, term()}
  when Credential::map(), State::state(), Extra::extra(), AuthData::binary(), AuthCache::map().

-callback destroy(State)
    -> ok
    when State::state().

-callback import_users(Filename, State)
    -> ok
     | {error, term()}
    when Filename::binary(), State::state().

-callback add_user(UserInfo, State)
    -> {ok, User}
     | {error, term()}
    when UserInfo::user_info(), State::state(), User::user_info().

-callback delete_user(UserID, State)
    -> ok
     | {error, term()}
    when UserID::binary(), State::state().

-callback update_user(UserID, UserInfo, State)
    -> {ok, User}
     | {error, term()}
    when UserID::binary(), UserInfo::map(), State::state(), User::user_info().

-callback lookup_user(UserID, UserInfo, State)
    -> {ok, User}
     | {error, term()}
    when UserID::binary(), UserInfo::map(), State::state(), User::user_info().

-callback list_users(State)
    -> {ok, Users}
    when State::state(), Users::[user_info()].

-optional_callbacks([ import_users/2
                    , add_user/2
                    , delete_user/2
                    , update_user/3
                    , lookup_user/3
                    , list_users/1
                    , check_config/1
                    ]).

%%------------------------------------------------------------------------------
%% Authenticate
%%------------------------------------------------------------------------------

authenticate(#{listener := Listener, protocol := Protocol} = Credential, _AuthResult) ->
    Authenticators = get_authenticators(Listener, global_chain(Protocol)),
    case get_enabled(Authenticators) of
        [] -> ignore;
        NAuthenticators -> do_authenticate(NAuthenticators, Credential)
    end.

do_authenticate([], _) ->
    {stop, {error, not_authorized}};
do_authenticate([#authenticator{id = ID, provider = Provider, state = State} | More], Credential) ->
    try Provider:authenticate(Credential, State) of
        ignore ->
            do_authenticate(More, Credential);
        Result ->
            %% {ok, Extra}
            %% {ok, Extra, AuthData}
            %% {continue, AuthCache}
            %% {continue, AuthData, AuthCache}
            %% {error, Reason}
            {stop, Result}
    catch
        Class:Reason:Stacktrace ->
            ?SLOG(warning, #{msg => "unexpected_error_in_authentication",
                             exception => Class,
                             reason => Reason,
                             stacktrace => Stacktrace,
                             authenticator => ID}),
            do_authenticate(More, Credential)
    end.

get_authenticators(Listener, Global) ->
    case ets:lookup(?CHAINS_TAB, Listener) of
        [#chain{authenticators = Authenticators}] ->
            Authenticators;
        _ ->
            case ets:lookup(?CHAINS_TAB, Global) of
                [#chain{authenticators = Authenticators}] ->
                    Authenticators;
                _ ->
                    []
            end
    end.

get_enabled(Authenticators) ->
    [Authenticator || Authenticator <- Authenticators, Authenticator#authenticator.enable =:= true].

%%------------------------------------------------------------------------------
%% APIs
%%------------------------------------------------------------------------------

pre_config_update(UpdateReq, OldConfig) ->
    emqx_authentication_config:pre_config_update(UpdateReq, OldConfig).

post_config_update(UpdateReq, NewConfig, OldConfig, AppEnvs) ->
    emqx_authentication_config:post_config_update(UpdateReq, NewConfig, OldConfig, AppEnvs).

%% @doc Get all registered authentication providers.
get_providers() ->
    call(get_providers).

%% @doc Get authenticator identifier from its config.
%% The authenticator config must contain a 'mechanism' key
%% and maybe a 'backend' key.
%% This function works with both parsed (atom keys) and raw (binary keys)
%% configurations.
authenticator_id(Config) ->
    emqx_authentication_config:authenticator_id(Config).

%% @doc Call this API to initialize authenticators implemented in another APP.
-spec initialize_authentication(chain_name(), [config()]) -> ok.
initialize_authentication(_, []) -> ok;
initialize_authentication(ChainName, AuthenticatorsConfig) ->
    _ = create_chain(ChainName),
    CheckedConfig = to_list(AuthenticatorsConfig),
    lists:foreach(fun(AuthenticatorConfig) ->
        case create_authenticator(ChainName, AuthenticatorConfig) of
            {ok, _} ->
                ok;
            {error, Reason} ->
                ?SLOG(error, #{
                    msg => "failed_to_create_authenticator",
                    authenticator => authenticator_id(AuthenticatorConfig),
                    reason => Reason
                })
        end
    end, CheckedConfig).

-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

-spec stop() -> ok.
stop() ->
    gen_server:stop(?MODULE).

%% @doc Register authentication providers.
%% A provider is a tuple of `AuthNType' the module which implements
%% the authenticator callbacks.
%% For example, ``[{{'password-based', redis}, emqx_authn_redis}]''
%% NOTE: Later registered provider may override earlier registered if they
%% happen to clash the same `AuthNType'.
-spec register_providers([{authn_type(), module()}]) -> ok.
register_providers(Providers) ->
    call({register_providers, Providers}).

-spec register_provider(authn_type(), module()) -> ok.
register_provider(AuthNType, Provider) ->
    register_providers([{AuthNType, Provider}]).

-spec deregister_providers([authn_type()]) -> ok.
deregister_providers(AuthNTypes) when is_list(AuthNTypes) ->
    call({deregister_providers, AuthNTypes}).

-spec deregister_provider(authn_type()) -> ok.
deregister_provider(AuthNType) ->
    deregister_providers([AuthNType]).

-spec create_chain(chain_name()) -> {ok, chain()} | {error, term()}.
create_chain(Name) ->
    call({create_chain, Name}).

-spec delete_chain(chain_name()) -> ok | {error, term()}.
delete_chain(Name) ->
    call({delete_chain, Name}).

-spec lookup_chain(chain_name()) -> {ok, chain()} | {error, term()}.
lookup_chain(Name) ->
    case ets:lookup(?CHAINS_TAB, Name) of
        [] ->
            {error, {not_found, {chain, Name}}};
        [Chain] ->
            {ok, serialize_chain(Chain)}
    end.

-spec list_chains() -> {ok, [chain()]}.
list_chains() ->
    Chains = ets:tab2list(?CHAINS_TAB),
    {ok, [serialize_chain(Chain) || Chain <- Chains]}.

-spec list_chain_names() -> {ok, [atom()]}.
list_chain_names() ->
    Select = ets:fun2ms(fun(#chain{name = Name}) -> Name end),
    ChainNames = ets:select(?CHAINS_TAB, Select),
    {ok, ChainNames}.

-spec create_authenticator(chain_name(), config()) -> {ok, authenticator()} | {error, term()}.
create_authenticator(ChainName, Config) ->
    call({create_authenticator, ChainName, Config}).

-spec delete_authenticator(chain_name(), authenticator_id()) -> ok | {error, term()}.
delete_authenticator(ChainName, AuthenticatorID) ->
    call({delete_authenticator, ChainName, AuthenticatorID}).

-spec update_authenticator(chain_name(), authenticator_id(), config()) -> {ok, authenticator()} | {error, term()}.
update_authenticator(ChainName, AuthenticatorID, Config) ->
    call({update_authenticator, ChainName, AuthenticatorID, Config}).

-spec lookup_authenticator(chain_name(), authenticator_id()) -> {ok, authenticator()} | {error, term()}.
lookup_authenticator(ChainName, AuthenticatorID) ->
    case ets:lookup(?CHAINS_TAB, ChainName) of
        [] ->
            {error, {not_found, {chain, ChainName}}};
        [#chain{authenticators = Authenticators}] ->
            case lists:keyfind(AuthenticatorID, #authenticator.id, Authenticators) of
                false ->
                    {error, {not_found, {authenticator, AuthenticatorID}}};
                Authenticator ->
                    {ok, serialize_authenticator(Authenticator)}
            end
    end.

-spec list_authenticators(chain_name()) -> {ok, [authenticator()]} | {error, term()}.
list_authenticators(ChainName) ->
    case ets:lookup(?CHAINS_TAB, ChainName) of
        [] ->
            {error, {not_found, {chain, ChainName}}};
        [#chain{authenticators = Authenticators}] ->
            {ok, serialize_authenticators(Authenticators)}
    end.

-spec move_authenticator(chain_name(), authenticator_id(), position()) -> ok | {error, term()}.
move_authenticator(ChainName, AuthenticatorID, Position) ->
    call({move_authenticator, ChainName, AuthenticatorID, Position}).

-spec import_users(chain_name(), authenticator_id(), binary()) -> ok | {error, term()}.
import_users(ChainName, AuthenticatorID, Filename) ->
    call({import_users, ChainName, AuthenticatorID, Filename}).

-spec add_user(chain_name(), authenticator_id(), user_info()) -> {ok, user_info()} | {error, term()}.
add_user(ChainName, AuthenticatorID, UserInfo) ->
    call({add_user, ChainName, AuthenticatorID, UserInfo}).

-spec delete_user(chain_name(), authenticator_id(), binary()) -> ok | {error, term()}.
delete_user(ChainName, AuthenticatorID, UserID) ->
    call({delete_user, ChainName, AuthenticatorID, UserID}).

-spec update_user(chain_name(), authenticator_id(), binary(), map()) -> {ok, user_info()} | {error, term()}.
update_user(ChainName, AuthenticatorID, UserID, NewUserInfo) ->
    call({update_user, ChainName, AuthenticatorID, UserID, NewUserInfo}).

-spec lookup_user(chain_name(), authenticator_id(), binary()) -> {ok, user_info()} | {error, term()}.
lookup_user(ChainName, AuthenticatorID, UserID) ->
    call({lookup_user, ChainName, AuthenticatorID, UserID}).

-spec list_users(chain_name(), authenticator_id(), map()) -> {ok, [user_info()]} | {error, term()}.
list_users(ChainName, AuthenticatorID, Params) ->
    call({list_users, ChainName, AuthenticatorID, Params}).

%%--------------------------------------------------------------------
%% gen_server callbacks
%%--------------------------------------------------------------------

init(_Opts) ->
    _ = ets:new(?CHAINS_TAB, [ named_table, set, public
                             , {keypos, #chain.name}
                             , {read_concurrency, true}]),
    ok = emqx_config_handler:add_handler([authentication], ?MODULE),
    ok = emqx_config_handler:add_handler([listeners, '?', '?', authentication], ?MODULE),
    {ok, #{hooked => false, providers => #{}}}.

handle_call(get_providers, _From, #{providers := Providers} = State) ->
    reply(Providers, State);
handle_call({register_providers, Providers}, _From,
            #{providers := Reg0} = State) ->
    case lists:filter(fun({T, _}) -> maps:is_key(T, Reg0) end, Providers) of
        [] ->
            Reg = lists:foldl(fun({AuthNType, Module}, Pin) ->
                                      Pin#{AuthNType => Module}
                              end, Reg0, Providers),
            reply(ok, State#{providers := Reg});
        Clashes ->
            reply({error, {authentication_type_clash, Clashes}}, State)
    end;

handle_call({deregister_providers, AuthNTypes}, _From, #{providers := Providers} = State) ->
    reply(ok, State#{providers := maps:without(AuthNTypes, Providers)});

handle_call({create_chain, Name}, _From, State) ->
    case ets:member(?CHAINS_TAB, Name) of
        true ->
            reply({error, {already_exists, {chain, Name}}}, State);
        false ->
            Chain = #chain{name = Name,
                           authenticators = []},
            true = ets:insert(?CHAINS_TAB, Chain),
            reply({ok, serialize_chain(Chain)}, State)
    end;

handle_call({delete_chain, Name}, _From, State) ->
    case ets:lookup(?CHAINS_TAB, Name) of
        [] ->
            reply({error, {not_found, {chain, Name}}}, State);
        [#chain{authenticators = Authenticators}] ->
            _ = [do_delete_authenticator(Authenticator) || Authenticator <- Authenticators],
            true = ets:delete(?CHAINS_TAB, Name),
            reply(ok, maybe_unhook(State))
    end;

handle_call({create_authenticator, ChainName, Config}, _From, #{providers := Providers} = State) ->
    UpdateFun =
        fun(#chain{authenticators = Authenticators} = Chain) ->
            AuthenticatorID = authenticator_id(Config),
            case lists:keymember(AuthenticatorID, #authenticator.id, Authenticators) of
                true ->
                    {error, {already_exists, {authenticator, AuthenticatorID}}};
                false ->
                    case do_create_authenticator(ChainName, AuthenticatorID, Config, Providers) of
                        {ok, Authenticator} ->
                            NAuthenticators = Authenticators ++ [Authenticator#authenticator{enable = maps:get(enable, Config)}],
                            true = ets:insert(?CHAINS_TAB, Chain#chain{authenticators = NAuthenticators}),
                            {ok, serialize_authenticator(Authenticator)};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end
        end,
    Reply = update_chain(ChainName, UpdateFun),
    reply(Reply, maybe_hook(State));

handle_call({delete_authenticator, ChainName, AuthenticatorID}, _From, State) ->
    UpdateFun =
        fun(#chain{authenticators = Authenticators} = Chain) ->
            case lists:keytake(AuthenticatorID, #authenticator.id, Authenticators) of
                false ->
                    {error, {not_found, {authenticator, AuthenticatorID}}};
                {value, Authenticator, NAuthenticators} ->
                    _ = do_delete_authenticator(Authenticator),
                    true = ets:insert(?CHAINS_TAB, Chain#chain{authenticators = NAuthenticators}),
                    ok
            end
        end,
    Reply = update_chain(ChainName, UpdateFun),
    reply(Reply, maybe_unhook(State));

handle_call({update_authenticator, ChainName, AuthenticatorID, Config}, _From, State) ->
    UpdateFun =
        fun(#chain{authenticators = Authenticators} = Chain) ->
            case lists:keyfind(AuthenticatorID, #authenticator.id, Authenticators) of
                false ->
                    {error, {not_found, {authenticator, AuthenticatorID}}};
                #authenticator{provider = Provider,
                               state    = #{version := Version} = ST} = Authenticator ->
                    case AuthenticatorID =:= authenticator_id(Config) of
                        true ->
                            Unique = unique(ChainName, AuthenticatorID, Version),
                            case Provider:update(Config#{'_unique' => Unique}, ST) of
                                {ok, NewST} ->
                                    NewAuthenticator = Authenticator#authenticator{state = switch_version(NewST#{version => Version}),
                                                                                   enable = maps:get(enable, Config)},
                                    NewAuthenticators = replace_authenticator(AuthenticatorID, NewAuthenticator, Authenticators),
                                    true = ets:insert(?CHAINS_TAB, Chain#chain{authenticators = NewAuthenticators}),
                                    {ok, serialize_authenticator(NewAuthenticator)};
                                {error, Reason} ->
                                    {error, Reason}
                            end;
                        false ->
                            {error, change_of_authentication_type_is_not_allowed}
                    end
            end
        end,
    Reply = update_chain(ChainName, UpdateFun),
    reply(Reply, State);

handle_call({move_authenticator, ChainName, AuthenticatorID, Position}, _From, State) ->
    UpdateFun =
        fun(#chain{authenticators = Authenticators} = Chain) ->
            case do_move_authenticator(AuthenticatorID, Authenticators, Position) of
                {ok, NAuthenticators} ->
                    true = ets:insert(?CHAINS_TAB, Chain#chain{authenticators = NAuthenticators}),
                    ok;
                {error, Reason} ->
                    {error, Reason}
            end
        end,
    Reply = update_chain(ChainName, UpdateFun),
    reply(Reply, State);

handle_call({import_users, ChainName, AuthenticatorID, Filename}, _From, State) ->
    Reply = call_authenticator(ChainName, AuthenticatorID, import_users, [Filename]),
    reply(Reply, State);

handle_call({add_user, ChainName, AuthenticatorID, UserInfo}, _From, State) ->
    Reply = call_authenticator(ChainName, AuthenticatorID, add_user, [UserInfo]),
    reply(Reply, State);

handle_call({delete_user, ChainName, AuthenticatorID, UserID}, _From, State) ->
    Reply = call_authenticator(ChainName, AuthenticatorID, delete_user, [UserID]),
    reply(Reply, State);

handle_call({update_user, ChainName, AuthenticatorID, UserID, NewUserInfo}, _From, State) ->
    Reply = call_authenticator(ChainName, AuthenticatorID, update_user, [UserID, NewUserInfo]),
    reply(Reply, State);

handle_call({lookup_user, ChainName, AuthenticatorID, UserID}, _From, State) ->
    Reply = call_authenticator(ChainName, AuthenticatorID, lookup_user, [UserID]),
    reply(Reply, State);

handle_call({list_users, ChainName, AuthenticatorID, PageParams}, _From, State) ->
    Reply = call_authenticator(ChainName, AuthenticatorID, list_users, [PageParams]),
    reply(Reply, State);

handle_call(Req, _From, State) ->
    ?SLOG(error, #{msg => "unexpected_call", call => Req}),
    {reply, ignored, State}.

handle_cast(Req, State) ->
    ?SLOG(error, #{msg => "unexpected_cast", cast => Req}),
    {noreply, State}.

handle_info(Info, State) ->
    ?SLOG(error, #{msg => "unexpected_info", info => Info}),
    {noreply, State}.

terminate(Reason, _State) ->
    case Reason of
        normal -> ok;
        {shutdown, _} -> ok;
        Other -> ?SLOG(error, #{msg => "emqx_authentication_terminating",
                                reason => Other})
    end,
    emqx_config_handler:remove_handler([authentication]),
    emqx_config_handler:remove_handler([listeners, '?', '?', authentication]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

reply(Reply, State) ->
    {reply, Reply, State}.

global_chain(mqtt) ->
    'mqtt:global';
global_chain('mqtt-sn') ->
    'mqtt-sn:global';
global_chain(coap) ->
    'coap:global';
global_chain(lwm2m) ->
    'lwm2m:global';
global_chain(stomp) ->
    'stomp:global';
global_chain(_) ->
    'unknown:global'.

maybe_hook(#{hooked := false} = State) ->
    case lists:any(fun(#chain{authenticators = []}) -> false;
                      (_) -> true
                   end, ets:tab2list(?CHAINS_TAB)) of
        true ->
            _ = emqx:hook('client.authenticate', {?MODULE, authenticate, []}),
            State#{hooked => true};
        false ->
            State
    end;
maybe_hook(State) ->
    State.

maybe_unhook(#{hooked := true} = State) ->
    case lists:all(fun(#chain{authenticators = []}) -> true;
                      (_) -> false
                   end, ets:tab2list(?CHAINS_TAB)) of
        true ->
            _ = emqx:unhook('client.authenticate', {?MODULE, authenticate, []}),
            State#{hooked => false};
        false ->
            State
    end;
maybe_unhook(State) ->
    State.

do_create_authenticator(ChainName, AuthenticatorID, #{enable := Enable} = Config, Providers) ->
    case maps:get(authn_type(Config), Providers, undefined) of
        undefined ->
            {error, no_available_provider};
        Provider ->
            Unique = unique(ChainName, AuthenticatorID, ?VER_1),
            case Provider:create(Config#{'_unique' => Unique}) of
                {ok, State} ->
                    Authenticator = #authenticator{id = AuthenticatorID,
                                                   provider = Provider,
                                                   enable = Enable,
                                                   state = switch_version(State)},
                    {ok, Authenticator};
                {error, Reason} ->
                    {error, Reason}
            end
    end.

do_delete_authenticator(#authenticator{provider = Provider, state = State}) ->
    _ = Provider:destroy(State),
    ok.

replace_authenticator(ID, Authenticator, Authenticators) ->
    lists:keyreplace(ID, #authenticator.id, Authenticators, Authenticator).

do_move_authenticator(ID, Authenticators, Position) ->
    case lists:keytake(ID, #authenticator.id, Authenticators) of
        false ->
            {error, {not_found, {authenticator, ID}}};
        {value, Authenticator, NAuthenticators} ->
            case Position of
                top ->
                    {ok, [Authenticator | NAuthenticators]};
                bottom ->
                    {ok, NAuthenticators ++ [Authenticator]};
                {before, ID0} ->
                    insert(Authenticator, NAuthenticators, ID0, [])
            end
    end.

insert(_, [], ID, _) ->
    {error, {not_found, {authenticator, ID}}};
insert(Authenticator, [#authenticator{id = ID} | _] = Authenticators, ID, Acc) ->
    {ok, lists:reverse(Acc) ++ [Authenticator | Authenticators]};
insert(Authenticator, [Authenticator0 | More], ID, Acc) ->
    insert(Authenticator, More, ID, [Authenticator0 | Acc]).

update_chain(ChainName, UpdateFun) ->
    case ets:lookup(?CHAINS_TAB, ChainName) of
        [] ->
            {error, {not_found, {chain, ChainName}}};
        [Chain] ->
            UpdateFun(Chain)
    end.

call_authenticator(ChainName, AuthenticatorID, Func, Args) ->
    UpdateFun =
        fun(#chain{authenticators = Authenticators}) ->
            case lists:keyfind(AuthenticatorID, #authenticator.id, Authenticators) of
                false ->
                    {error, {not_found, {authenticator, AuthenticatorID}}};
                #authenticator{provider = Provider, state = State} ->
                    case erlang:function_exported(Provider, Func, length(Args) + 1) of
                        true ->
                            erlang:apply(Provider, Func, Args ++ [State]);
                        false ->
                            {error, unsupported_operation}
                    end
            end
        end,
    update_chain(ChainName, UpdateFun).

serialize_chain(#chain{name = Name,
                       authenticators = Authenticators}) ->
    #{ name => Name
     , authenticators => serialize_authenticators(Authenticators)
     }.

serialize_authenticators(Authenticators) ->
    [serialize_authenticator(Authenticator) || Authenticator <- Authenticators].

serialize_authenticator(#authenticator{id = ID,
                                       provider = Provider,
                                       enable = Enable,
                                       state = State}) ->
    #{ id => ID
     , provider => Provider
     , enable => Enable
     , state => State
     }.

unique(ChainName, AuthenticatorID, Version) ->
    NChainName = atom_to_binary(ChainName),
    <<NChainName/binary, "/", AuthenticatorID/binary, ":", Version/binary>>.

switch_version(State = #{version := ?VER_1}) ->
    State#{version := ?VER_2};
switch_version(State = #{version := ?VER_2}) ->
    State#{version := ?VER_1};
switch_version(State) ->
    State#{version => ?VER_2}.

authn_type(#{mechanism := Mechanism, backend := Backend}) ->
    {Mechanism, Backend};
authn_type(#{mechanism := Mechanism}) ->
    Mechanism.

to_list(undefined) -> [];
to_list(M) when M =:= #{} -> [];
to_list(M) when is_map(M) -> [M];
to_list(L) when is_list(L) -> L.

call(Call) -> gen_server:call(?MODULE, Call, infinity).
