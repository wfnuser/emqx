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

-module(emqx_mgmt_cli).

-include_lib("emqx/include/emqx.hrl").
-include_lib("emqx/include/emqx_mqtt.hrl").

-include("emqx_mgmt.hrl").

-define(PRINT_CMD(Cmd, Descr), io:format("~-48s# ~ts~n", [Cmd, Descr])).

-export([load/0]).

-export([ status/1
        , broker/1
        , cluster/1
        , clients/1
        , routes/1
        , subscriptions/1
        , plugins/1
        , listeners/1
        , vm/1
        , mnesia/1
        , trace/1
        , log/1
        , authz/1
        , olp/1
        ]).

-define(PROC_INFOKEYS, [status,
                        memory,
                        message_queue_len,
                        total_heap_size,
                        heap_size,
                        stack_size,
                        reductions]).

-define(MAX_LIMIT, 10000).

-define(APP, emqx).

-spec(load() -> ok).
load() ->
    Cmds = [Fun || {Fun, _} <- ?MODULE:module_info(exports), is_cmd(Fun)],
    lists:foreach(fun(Cmd) -> emqx_ctl:register_command(Cmd, {?MODULE, Cmd}, []) end, Cmds).

is_cmd(Fun) ->
    not lists:member(Fun, [init, load, module_info]).

%%--------------------------------------------------------------------
%% @doc Node status

status([]) ->
    {InternalStatus, _ProvidedStatus} = init:get_status(),
    emqx_ctl:print("Node ~p ~ts is ~p~n", [node(), emqx_app:get_release(), InternalStatus]);
status(_) ->
     emqx_ctl:usage("status", "Show broker status").

%%--------------------------------------------------------------------
%% @doc Query broker

broker([]) ->
    Funs = [sysdescr, version, datetime],
    [emqx_ctl:print("~-10s: ~ts~n", [Fun, emqx_sys:Fun()]) || Fun <- Funs],
    emqx_ctl:print("~-10s: ~p~n", [uptime, emqx_sys:uptime()]);

broker(["stats"]) ->
    [emqx_ctl:print("~-30s: ~w~n", [Stat, Val])
     || {Stat, Val} <- lists:sort(emqx_stats:getstats())];

broker(["metrics"]) ->
    [emqx_ctl:print("~-30s: ~w~n", [Metric, Val])
     || {Metric, Val} <- lists:sort(emqx_metrics:all())];

broker(_) ->
    emqx_ctl:usage([{"broker",         "Show broker version, uptime and description"},
                    {"broker stats",   "Show broker statistics of clients, topics, subscribers"},
                    {"broker metrics", "Show broker metrics"}]).

%%-----------------------------------------------------------------------------
%% @doc Cluster with other nodes

cluster(["join", SNode]) ->
    case ekka:join(ekka_node:parse_name(SNode)) of
        ok ->
            emqx_ctl:print("Join the cluster successfully.~n"),
            cluster(["status"]);
        ignore ->
            emqx_ctl:print("Ignore.~n");
        {error, Error} ->
            emqx_ctl:print("Failed to join the cluster: ~0p~n", [Error])
    end;

cluster(["leave"]) ->
    case ekka:leave() of
        ok ->
            emqx_ctl:print("Leave the cluster successfully.~n"),
            cluster(["status"]);
        {error, Error} ->
            emqx_ctl:print("Failed to leave the cluster: ~0p~n", [Error])
    end;

cluster(["force-leave", SNode]) ->
    case ekka:force_leave(ekka_node:parse_name(SNode)) of
        ok ->
            emqx_ctl:print("Remove the node from cluster successfully.~n"),
            cluster(["status"]);
        ignore ->
            emqx_ctl:print("Ignore.~n");
        {error, Error} ->
            emqx_ctl:print("Failed to remove the node from cluster: ~0p~n", [Error])
    end;

cluster(["status"]) ->
    emqx_ctl:print("Cluster status: ~p~n", [ekka_cluster:info()]);

cluster(_) ->
    emqx_ctl:usage([{"cluster join <Node>",       "Join the cluster"},
                    {"cluster leave",             "Leave the cluster"},
                    {"cluster force-leave <Node>","Force the node leave from cluster"},
                    {"cluster status",            "Cluster status"}]).

%%--------------------------------------------------------------------
%% @doc Query clients

clients(["list"]) ->
    dump(emqx_channel, client);

clients(["show", ClientId]) ->
    if_client(ClientId, fun print/1);

clients(["kick", ClientId]) ->
    ok = emqx_cm:kick_session(bin(ClientId)),
    emqx_ctl:print("ok~n");

clients(_) ->
    emqx_ctl:usage([{"clients list",            "List all clients"},
                    {"clients show <ClientId>", "Show a client"},
                    {"clients kick <ClientId>", "Kick out a client"}]).

if_client(ClientId, Fun) ->
    case ets:lookup(emqx_channel, (bin(ClientId))) of
        [] -> emqx_ctl:print("Not Found.~n");
        [Channel]    -> Fun({client, Channel})
    end.

%%--------------------------------------------------------------------
%% @doc Routes Command

routes(["list"]) ->
    dump(emqx_route);

routes(["show", Topic]) ->
    Routes = ets:lookup(emqx_route, bin(Topic)),
    [print({emqx_route, Route}) || Route <- Routes];

routes(_) ->
    emqx_ctl:usage([{"routes list",         "List all routes"},
                    {"routes show <Topic>", "Show a route"}]).

subscriptions(["list"]) ->
    lists:foreach(fun(Suboption) ->
                        print({emqx_suboption, Suboption})
                  end, ets:tab2list(emqx_suboption));

subscriptions(["show", ClientId]) ->
    case ets:lookup(emqx_subid, bin(ClientId)) of
        [] ->
            emqx_ctl:print("Not Found.~n");
        [{_, Pid}] ->
            case ets:match_object(emqx_suboption, {{Pid, '_'}, '_'}) of
                [] -> emqx_ctl:print("Not Found.~n");
                Suboption ->
                    [print({emqx_suboption, Sub}) || Sub <- Suboption]
            end
    end;

subscriptions(["add", ClientId, Topic, QoS]) ->
   if_valid_qos(QoS, fun(IntQos) ->
                        case ets:lookup(emqx_channel, bin(ClientId)) of
                            [] -> emqx_ctl:print("Error: Channel not found!");
                            [{_, Pid}] ->
                                {Topic1, Options} = emqx_topic:parse(bin(Topic)),
                                Pid ! {subscribe, [{Topic1, Options#{qos => IntQos}}]},
                                emqx_ctl:print("ok~n")
                        end
                     end);

subscriptions(["del", ClientId, Topic]) ->
    case ets:lookup(emqx_channel, bin(ClientId)) of
        [] -> emqx_ctl:print("Error: Channel not found!");
        [{_, Pid}] ->
            Pid ! {unsubscribe, [emqx_topic:parse(bin(Topic))]},
            emqx_ctl:print("ok~n")
    end;

subscriptions(_) ->
    emqx_ctl:usage(
      [{"subscriptions list",                         "List all subscriptions"},
       {"subscriptions show <ClientId>",              "Show subscriptions of a client"},
       {"subscriptions add <ClientId> <Topic> <QoS>", "Add a static subscription manually"},
       {"subscriptions del <ClientId> <Topic>",       "Delete a static subscription manually"}]).

if_valid_qos(QoS, Fun) ->
    try list_to_integer(QoS) of
        Int when ?IS_QOS(Int) -> Fun(Int);
        _ -> emqx_ctl:print("QoS should be 0, 1, 2~n")
    catch _:_ ->
        emqx_ctl:print("QoS should be 0, 1, 2~n")
    end.

plugins(["list"]) ->
    lists:foreach(fun print/1, emqx_plugins:list());

plugins(["load", Name]) ->
    case emqx_plugins:load(list_to_atom(Name)) of
        ok ->
            emqx_ctl:print("Plugin ~ts loaded successfully.~n", [Name]);
        {error, Reason}   ->
            emqx_ctl:print("Load plugin ~ts error: ~p.~n", [Name, Reason])
    end;

plugins(["unload", "emqx_management"])->
    emqx_ctl:print("Plugin emqx_management can not be unloaded.~n");

plugins(["unload", Name]) ->
    case emqx_plugins:unload(list_to_atom(Name)) of
        ok ->
            emqx_ctl:print("Plugin ~ts unloaded successfully.~n", [Name]);
        {error, Reason} ->
            emqx_ctl:print("Unload plugin ~ts error: ~p.~n", [Name, Reason])
    end;

plugins(["reload", Name]) ->
    try list_to_existing_atom(Name) of
        PluginName ->
            case emqx_mgmt:reload_plugin(node(), PluginName) of
                ok ->
                    emqx_ctl:print("Plugin ~ts reloaded successfully.~n", [Name]);
                {error, Reason} ->
                    emqx_ctl:print("Reload plugin ~ts error: ~p.~n", [Name, Reason])
            end
    catch
        error:badarg ->
            emqx_ctl:print("Reload plugin ~ts error: The plugin doesn't exist.~n", [Name])
    end;

plugins(_) ->
    emqx_ctl:usage([{"plugins list",            "Show loaded plugins"},
                    {"plugins load <Plugin>",   "Load plugin"},
                    {"plugins unload <Plugin>", "Unload plugin"},
                    {"plugins reload <Plugin>", "Reload plugin"}
                   ]).

%%--------------------------------------------------------------------
%% @doc vm command

vm([]) ->
    vm(["all"]);

vm(["all"]) ->
    [vm([Name]) || Name <- ["load", "memory", "process", "io", "ports"]];

vm(["load"]) ->
    [emqx_ctl:print("cpu/~-20s: ~ts~n", [L, V]) || {L, V} <- emqx_vm:loads()];

vm(["memory"]) ->
    [emqx_ctl:print("memory/~-17s: ~w~n", [Cat, Val]) || {Cat, Val} <- erlang:memory()];

vm(["process"]) ->
    [emqx_ctl:print("process/~-16s: ~w~n", [Name, erlang:system_info(Key)])
     || {Name, Key} <- [{limit, process_limit}, {count, process_count}]];

vm(["io"]) ->
    IoInfo = lists:usort(lists:flatten(erlang:system_info(check_io))),
    [emqx_ctl:print("io/~-21s: ~w~n", [Key, proplists:get_value(Key, IoInfo)])
     || Key <- [max_fds, active_fds]];

vm(["ports"]) ->
    [emqx_ctl:print("ports/~-18s: ~w~n", [Name, erlang:system_info(Key)])
     || {Name, Key} <- [{count, port_count}, {limit, port_limit}]];

vm(_) ->
    emqx_ctl:usage([{"vm all",     "Show info of Erlang VM"},
                    {"vm load",    "Show load of Erlang VM"},
                    {"vm memory",  "Show memory of Erlang VM"},
                    {"vm process", "Show process of Erlang VM"},
                    {"vm io",      "Show IO of Erlang VM"},
                    {"vm ports",   "Show Ports of Erlang VM"}]).

%%--------------------------------------------------------------------
%% @doc mnesia Command

mnesia([]) ->
    mnesia:system_info();

mnesia(_) ->
    emqx_ctl:usage([{"mnesia", "Mnesia system info"}]).

%%--------------------------------------------------------------------
%% @doc Logger Command

log(["set-level", Level]) ->
    case emqx_logger:set_log_level(list_to_atom(Level)) of
        ok -> emqx_ctl:print("~ts~n", [Level]);
        Error -> emqx_ctl:print("[error] set overall log level failed: ~p~n", [Error])
    end;

log(["primary-level"]) ->
    Level = emqx_logger:get_primary_log_level(),
    emqx_ctl:print("~ts~n", [Level]);

log(["primary-level", Level]) ->
    _ = emqx_logger:set_primary_log_level(list_to_atom(Level)),
    emqx_ctl:print("~ts~n", [emqx_logger:get_primary_log_level()]);

log(["handlers", "list"]) ->
    _ = [emqx_ctl:print(
            "LogHandler(id=~ts, level=~ts, destination=~ts, status=~ts)~n",
            [Id, Level, Dst, Status]
          )
        || #{id := Id,
             level := Level,
             dst := Dst,
             status := Status} <- emqx_logger:get_log_handlers()],
    ok;

log(["handlers", "start", HandlerId]) ->
    case emqx_logger:start_log_handler(list_to_atom(HandlerId)) of
        ok -> emqx_ctl:print("log handler ~ts started~n", [HandlerId]);
        {error, Reason} ->
            emqx_ctl:print("[error] failed to start log handler ~ts: ~p~n", [HandlerId, Reason])
    end;

log(["handlers", "stop", HandlerId]) ->
    case emqx_logger:stop_log_handler(list_to_atom(HandlerId)) of
        ok -> emqx_ctl:print("log handler ~ts stopped~n", [HandlerId]);
        {error, Reason} ->
            emqx_ctl:print("[error] failed to stop log handler ~ts: ~p~n", [HandlerId, Reason])
    end;

log(["handlers", "set-level", HandlerId, Level]) ->
    case emqx_logger:set_log_handler_level(list_to_atom(HandlerId), list_to_atom(Level)) of
        ok ->
            #{level := NewLevel} = emqx_logger:get_log_handler(list_to_atom(HandlerId)),
            emqx_ctl:print("~ts~n", [NewLevel]);
        {error, Error} ->
            emqx_ctl:print("[error] ~p~n", [Error])
    end;

log(_) ->
    emqx_ctl:usage(
      [{"log set-level <Level>", "Set the overall log level"},
       {"log primary-level", "Show the primary log level now"},
       {"log primary-level <Level>","Set the primary log level"},
       {"log handlers list", "Show log handlers"},
       {"log handlers start <HandlerId>", "Start a log handler"},
       {"log handlers stop  <HandlerId>", "Stop a log handler"},
       {"log handlers set-level <HandlerId> <Level>", "Set log level of a log handler"}]).

%%--------------------------------------------------------------------
%% @doc Trace Command

trace(["list"]) ->
    lists:foreach(fun({{Who, Name}, {Level, LogFile}}) ->
        emqx_ctl:print(
            "Trace(~ts=~ts, level=~ts, destination=~p)~n",
            [Who, Name, Level, LogFile]
         )
    end, emqx_tracer:lookup_traces());

trace(["stop", "client", ClientId]) ->
    trace_off(clientid, ClientId);

trace(["start", "client", ClientId, LogFile]) ->
    trace_on(clientid, ClientId, all, LogFile);

trace(["start", "client", ClientId, LogFile, Level]) ->
    trace_on(clientid, ClientId, list_to_atom(Level), LogFile);

trace(["stop", "topic", Topic]) ->
    trace_off(topic, Topic);

trace(["start", "topic", Topic, LogFile]) ->
    trace_on(topic, Topic, all, LogFile);

trace(["start", "topic", Topic, LogFile, Level]) ->
    trace_on(topic, Topic, list_to_atom(Level), LogFile);

trace(_) ->
    emqx_ctl:usage([{"trace list", "List all traces started"},
                    {"trace start client <ClientId> <File> [<Level>]", "Traces for a client"},
                    {"trace stop  client <ClientId>", "Stop tracing for a client"},
                    {"trace start topic  <Topic>    <File> [<Level>] ", "Traces for a topic"},
                    {"trace stop  topic  <Topic> ", "Stop tracing for a topic"}]).

trace_on(Who, Name, Level, LogFile) ->
    case emqx_tracer:start_trace({Who, iolist_to_binary(Name)}, Level, LogFile) of
        ok ->
            emqx_ctl:print("trace ~ts ~ts successfully~n", [Who, Name]);
        {error, Error} ->
            emqx_ctl:print("[error] trace ~ts ~ts: ~p~n", [Who, Name, Error])
    end.

trace_off(Who, Name) ->
    case emqx_tracer:stop_trace({Who, iolist_to_binary(Name)}) of
        ok ->
            emqx_ctl:print("stop tracing ~ts ~ts successfully~n", [Who, Name]);
        {error, Error} ->
            emqx_ctl:print("[error] stop tracing ~ts ~ts: ~p~n", [Who, Name, Error])
    end.

%%--------------------------------------------------------------------
%% @doc Listeners Command

listeners([]) ->
    lists:foreach(fun({ID, Conf}) ->
                {Host, Port}    = maps:get(bind, Conf),
                Acceptors       = maps:get(acceptors, Conf),
                ProxyProtocol   = maps:get(proxy_protocol, Conf, undefined),
                Running         = maps:get(running, Conf),
                CurrentConns    = case emqx_listeners:current_conns(ID, {Host, Port}) of
                                      {error, _} -> [];
                                      CC         -> [{current_conn, CC}]
                                  end,
                MaxConn         = case emqx_listeners:max_conns(ID, {Host, Port}) of
                                      {error, _} -> [];
                                      MC         -> [{max_conns, MC}]
                                  end,
                Info = [
                    {listen_on,         {string, format_listen_on(Port)}},
                    {acceptors,         Acceptors},
                    {proxy_protocol,    ProxyProtocol},
                    {running,           Running}
                ] ++ CurrentConns ++ MaxConn,
                emqx_ctl:print("~ts~n", [ID]),
                lists:foreach(fun indent_print/1, Info)
            end, emqx_listeners:list());

listeners(["stop", ListenerId]) ->
    case emqx_listeners:stop_listener(list_to_atom(ListenerId)) of
        ok ->
            emqx_ctl:print("Stop ~ts listener successfully.~n", [ListenerId]);
        {error, Error} ->
            emqx_ctl:print("Failed to stop ~ts listener: ~0p~n", [ListenerId, Error])
    end;

listeners(["start", ListenerId]) ->
    case emqx_listeners:start_listener(list_to_atom(ListenerId)) of
        ok ->
            emqx_ctl:print("Started ~ts listener successfully.~n", [ListenerId]);
        {error, Error} ->
            emqx_ctl:print("Failed to start ~ts listener: ~0p~n", [ListenerId, Error])
    end;

listeners(["restart", ListenerId]) ->
    case emqx_listeners:restart_listener(list_to_atom(ListenerId)) of
        ok ->
            emqx_ctl:print("Restarted ~ts listener successfully.~n", [ListenerId]);
        {error, Error} ->
            emqx_ctl:print("Failed to restart ~ts listener: ~0p~n", [ListenerId, Error])
    end;

listeners(_) ->
    emqx_ctl:usage([{"listeners",                        "List listeners"},
                    {"listeners stop    <Identifier>",   "Stop a listener"},
                    {"listeners start   <Identifier>",   "Start a listener"},
                    {"listeners restart <Identifier>",   "Restart a listener"}
                   ]).

%%--------------------------------------------------------------------
%% @doc authz Command

authz(["cache-clean", "node", Node]) ->
    case emqx_mgmt:clean_authz_cache_all(erlang:list_to_existing_atom(Node)) of
        ok ->
            emqx_ctl:print("Authorization cache drain started on node ~ts.~n", [Node]);
        {error, Reason} ->
            emqx_ctl:print("Authorization drain failed on node ~ts: ~0p.~n", [Node, Reason])
    end;

authz(["cache-clean", "all"]) ->
    case emqx_mgmt:clean_authz_cache_all() of
        ok ->
            emqx_ctl:print("Started Authorization cache drain in all nodes~n");
        {error, Reason} ->
            emqx_ctl:print("Authorization cache-clean failed: ~p.~n", [Reason])
    end;

authz(["cache-clean", ClientId]) ->
    emqx_mgmt:clean_authz_cache(ClientId);

authz(_) ->
    emqx_ctl:usage(
      [{"authz cache-clean all",         "Clears authorization cache on all nodes"},
       {"authz cache-clean node <Node>", "Clears authorization cache on given node"},
       {"authz cache-clean <ClientId>",  "Clears authorization cache for given client"}
      ]).


%%--------------------------------------------------------------------
%% @doc OLP (Overload Protection related)
olp(["status"]) ->
    S = case emqx_olp:is_overloaded() of
            true -> "overloaded";
            false -> "not overloaded"
        end,
    emqx_ctl:print("~p is ~s ~n", [node(), S]);
olp(["disable"]) ->
    Res = emqx_olp:disable(),
    emqx_ctl:print("Disable overload protetion ~p : ~p ~n", [node(), Res]);
olp(["enable"]) ->
    Res = emqx_olp:enable(),
    emqx_ctl:print("Enable overload protection ~p : ~p ~n", [node(), Res]);
olp(_) ->
    emqx_ctl:usage([{"olp status",  "Return OLP status if system is overloaded"},
                    {"olp enable",  "Enable overload protection"},
                    {"olp disable", "Disable overload protection"}
                   ]).

%%--------------------------------------------------------------------
%% Dump ETS
%%--------------------------------------------------------------------

dump(Table) ->
    dump(Table, Table, ets:first(Table), []).

dump(Table, Tag) ->
    dump(Table, Tag, ets:first(Table), []).

dump(_Table, _, '$end_of_table', Result) ->
    lists:reverse(Result);

dump(Table, Tag, Key, Result) ->
    PrintValue = [print({Tag, Record}) || Record <- ets:lookup(Table, Key)],
    dump(Table, Tag, ets:next(Table, Key), [PrintValue | Result]).

print({_, []}) ->
    ok;

print({client, {ClientId, ChanPid}}) ->
    Attrs = case emqx_cm:get_chan_info(ClientId, ChanPid) of
                undefined -> #{};
                Attrs0 -> Attrs0
            end,
    Stats = case emqx_cm:get_chan_stats(ClientId, ChanPid) of
                undefined -> #{};
                Stats0 -> maps:from_list(Stats0)
            end,
    ClientInfo = maps:get(clientinfo, Attrs, #{}),
    ConnInfo = maps:get(conninfo, Attrs, #{}),
    Session = maps:get(session, Attrs, #{}),
    Connected = case maps:get(conn_state, Attrs) of
                    connected -> true;
                    _ -> false
                end,
    Info = lists:foldl(fun(Items, Acc) ->
                               maps:merge(Items, Acc)
                       end, #{connected => Connected},
                       [maps:with([subscriptions_cnt, inflight_cnt, awaiting_rel_cnt,
                                   mqueue_len, mqueue_dropped, send_msg], Stats),
                        maps:with([clientid, username], ClientInfo),
                        maps:with([peername, clean_start, keepalive, expiry_interval,
                                   connected_at, disconnected_at], ConnInfo),
                        maps:with([created_at], Session)]),
    InfoKeys = [clientid, username, peername, clean_start, keepalive,
                expiry_interval, subscriptions_cnt, inflight_cnt,
                awaiting_rel_cnt, send_msg, mqueue_len, mqueue_dropped,
                connected, created_at, connected_at] ++
                case maps:is_key(disconnected_at, Info) of
                    true  -> [disconnected_at];
                    false -> []
                end,
    Info1 = Info#{expiry_interval => maps:get(expiry_interval, Info) div 1000},
    emqx_ctl:print(
        "Client(~ts, username=~ts, peername=~ts, clean_start=~ts, "
        "keepalive=~w, session_expiry_interval=~w, subscriptions=~w, "
        "inflight=~w, awaiting_rel=~w, delivered_msgs=~w, enqueued_msgs=~w, "
        "dropped_msgs=~w, connected=~ts, created_at=~w, connected_at=~w"
        ++ case maps:is_key(disconnected_at, Info1) of
               true  -> ", disconnected_at=~w)~n";
               false -> ")~n"
           end,
        [format(K, maps:get(K, Info1)) || K <- InfoKeys]);

print({emqx_route, #route{topic = Topic, dest = {_, Node}}}) ->
    emqx_ctl:print("~ts -> ~ts~n", [Topic, Node]);
print({emqx_route, #route{topic = Topic, dest = Node}}) ->
    emqx_ctl:print("~ts -> ~ts~n", [Topic, Node]);

print(#plugin{name = Name, descr = Descr, active = Active}) ->
    emqx_ctl:print("Plugin(~ts, description=~ts, active=~ts)~n",
                  [Name, Descr, Active]);

print({emqx_suboption, {{Pid, Topic}, Options}}) when is_pid(Pid) ->
    emqx_ctl:print("~ts -> ~ts~n", [maps:get(subid, Options), Topic]).

format(_, undefined) ->
    undefined;

format(peername, {IPAddr, Port}) ->
    IPStr = emqx_mgmt_util:ntoa(IPAddr),
    io_lib:format("~ts:~p", [IPStr, Port]);

format(_, Val) ->
    Val.

bin(S) -> iolist_to_binary(S).

indent_print({Key, {string, Val}}) ->
    emqx_ctl:print("  ~-16s: ~ts~n", [Key, Val]);
indent_print({Key, Val}) ->
    emqx_ctl:print("  ~-16s: ~w~n", [Key, Val]).

format_listen_on(Port) when is_integer(Port) ->
    io_lib:format("0.0.0.0:~w", [Port]);
format_listen_on({Addr, Port}) when is_list(Addr) ->
    io_lib:format("~ts:~w", [Addr, Port]);
format_listen_on({Addr, Port}) when is_tuple(Addr) ->
    io_lib:format("~ts:~w", [inet:ntoa(Addr), Port]).
