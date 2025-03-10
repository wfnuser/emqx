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
-module(emqx_connector_mysql).

-include_lib("typerefl/include/types.hrl").
-include_lib("emqx_resource/include/emqx_resource_behaviour.hrl").
-include_lib("emqx/include/logger.hrl").

%% callbacks of behaviour emqx_resource
-export([ on_start/2
        , on_stop/2
        , on_query/4
        , on_health_check/2
        , on_jsonify/1
        ]).

-export([connect/1]).

-export([roots/0, fields/1]).

-export([do_health_check/1]).

%%=====================================================================
%% Hocon schema
roots() ->
    [{config, #{type => hoconsc:ref(?MODULE, config)}}].

fields(config) ->
    emqx_connector_schema_lib:relational_db_fields() ++
    emqx_connector_schema_lib:ssl_fields().

%%=====================================================================

on_jsonify(#{server := Server}= Config) ->
    Config#{server => emqx_connector_schema_lib:ip_port_to_string(Server)}.

%% ===================================================================
on_start(InstId, #{server := {Host, Port},
                   database := DB,
                   username := User,
                   password := Password,
                   auto_reconnect := AutoReconn,
                   pool_size := PoolSize,
                   ssl := SSL } = Config) ->
    ?SLOG(info, #{msg => "starting mysql connector",
                  connector => InstId, config => Config}),
    SslOpts = case maps:get(enable, SSL) of
        true ->
            [{ssl, [{server_name_indication, disable} |
                    emqx_plugin_libs_ssl:save_files_return_opts(SSL, "connectors", InstId)]}];
        false -> []
    end,
    Options = [{host, Host},
               {port, Port},
               {user, User},
               {password, Password},
               {database, DB},
               {auto_reconnect, reconn_interval(AutoReconn)},
               {pool_size, PoolSize}],
    PoolName = emqx_plugin_libs_pool:pool_name(InstId),
    _ = emqx_plugin_libs_pool:start_pool(PoolName, ?MODULE, Options ++ SslOpts),
    {ok, #{poolname => PoolName}}.

on_stop(InstId, #{poolname := PoolName}) ->
    ?SLOG(info, #{msg => "stopping mysql connector",
                  connector => InstId}),
    emqx_plugin_libs_pool:stop_pool(PoolName).

on_query(InstId, {sql, SQL}, AfterQuery, #{poolname := _PoolName} = State) ->
    on_query(InstId, {sql, SQL, [], default_timeout}, AfterQuery, State);
on_query(InstId, {sql, SQL, Params}, AfterQuery, #{poolname := _PoolName} = State) ->
    on_query(InstId, {sql, SQL, Params, default_timeout}, AfterQuery, State);
on_query(InstId, {sql, SQL, Params, Timeout}, AfterQuery, #{poolname := PoolName} = State) ->
    ?SLOG(debug, #{msg => "mysql connector received sql query",
        connector => InstId, sql => SQL, state => State}),
    case Result = ecpool:pick_and_do(PoolName, {mysql, query, [SQL, Params, Timeout]}, no_handover) of
        {error, Reason} ->
            ?SLOG(error, #{msg => "mysql connector do sql query failed",
                connector => InstId, sql => SQL, reason => Reason}),
            emqx_resource:query_failed(AfterQuery);
        _ ->
            emqx_resource:query_success(AfterQuery)
    end,
    Result.

on_health_check(_InstId, #{poolname := PoolName} = State) ->
    emqx_plugin_libs_pool:health_check(PoolName, fun ?MODULE:do_health_check/1, State).

do_health_check(Conn) ->
    ok == element(1, mysql:query(Conn, <<"SELECT count(1) AS T">>)).

%% ===================================================================
reconn_interval(true) -> 15;
reconn_interval(false) -> false.

connect(Options) ->
    mysql:start_link(Options).
