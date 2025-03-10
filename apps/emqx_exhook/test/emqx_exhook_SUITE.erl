%%--------------------------------------------------------------------
%% Copyright (c) 2020-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_exhook_SUITE).

-compile(export_all).
-compile(nowarn_export_all).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-define(CONF_DEFAULT, <<"
exhook: {
    servers: [
        { name: \"default\"
          url: \"http://127.0.0.1:9000\"
        }
    ]
}
">>).

%%--------------------------------------------------------------------
%% Setups
%%--------------------------------------------------------------------

all() -> emqx_common_test_helpers:all(?MODULE).

init_per_suite(Cfg) ->
    _ = emqx_exhook_demo_svr:start(),
    ok = emqx_config:init_load(emqx_exhook_schema, ?CONF_DEFAULT),
    emqx_common_test_helpers:start_apps([emqx_exhook]),
    Cfg.

end_per_suite(_Cfg) ->
    emqx_common_test_helpers:stop_apps([emqx_exhook]),
    emqx_exhook_demo_svr:stop().

%%--------------------------------------------------------------------
%% Test cases
%%--------------------------------------------------------------------

t_noserver_nohook(_) ->
    emqx_exhook:disable(<<"default">>),
    ?assertEqual([], ets:tab2list(emqx_hooks)),
    ok = emqx_exhook:enable(<<"default">>),
    ?assertNotEqual([], ets:tab2list(emqx_hooks)).

t_access_failed_if_no_server_running(_) ->
    emqx_exhook:disable(<<"default">>),
    ClientInfo = #{clientid => <<"user-id-1">>,
                   username => <<"usera">>,
                   peerhost => {127,0,0,1},
                   sockport => 1883,
                   protocol => mqtt,
                   mountpoint => undefined
                  },
    ?assertMatch({stop, {error, not_authorized}},
                 emqx_exhook_handler:on_client_authenticate(ClientInfo, #{auth_result => success})),

    ?assertMatch({stop, deny},
                 emqx_exhook_handler:on_client_authorize(ClientInfo, publish, <<"t/1">>, allow)),

    Message = emqx_message:make(<<"t/1">>, <<"abc">>),
    ?assertMatch({stop, Message},
                 emqx_exhook_handler:on_message_publish(Message)),
    emqx_exhook:enable(<<"default">>).

t_cli_list(_) ->
    meck_print(),
    ?assertEqual( [[emqx_exhook_server:format(emqx_exhook_mngr:server(Name)) || Name  <- emqx_exhook:list()]]
                , emqx_exhook_cli:cli(["server", "list"])
                ),
    unmeck_print().

t_cli_enable_disable(_) ->
    meck_print(),
    ?assertEqual([already_started], emqx_exhook_cli:cli(["server", "enable", "default"])),
    ?assertEqual(ok, emqx_exhook_cli:cli(["server", "disable", "default"])),
    ?assertEqual([["name=default, hooks=#{}, active=false"]], emqx_exhook_cli:cli(["server", "list"])),

    ?assertEqual([not_running], emqx_exhook_cli:cli(["server", "disable", "default"])),
    ?assertEqual(ok, emqx_exhook_cli:cli(["server", "enable", "default"])),
    unmeck_print().

t_cli_stats(_) ->
    meck_print(),
    _ = emqx_exhook_cli:cli(["server", "stats"]),
    _ = emqx_exhook_cli:cli(x),
    unmeck_print().

%%--------------------------------------------------------------------
%% Utils
%%--------------------------------------------------------------------

meck_print() ->
    meck:new(emqx_ctl, [passthrough, no_history, no_link]),
    meck:expect(emqx_ctl, print, fun(_) -> ok end),
    meck:expect(emqx_ctl, print, fun(_, Args) -> Args end).

unmeck_print() ->
    meck:unload(emqx_ctl).

loaded_exhook_hookpoints() ->
    lists:filtermap(fun(E) ->
        Name = element(2, E),
        Callbacks = element(3, E),
        case lists:any(fun is_exhook_callback/1, Callbacks) of
            true -> {true, Name};
            _ -> false
        end
    end, ets:tab2list(emqx_hooks)).

is_exhook_callback(Cb) ->
    Action = element(2, Cb),
    emqx_exhook_handler == element(1, Action).
