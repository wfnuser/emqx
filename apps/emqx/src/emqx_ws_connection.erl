%%--------------------------------------------------------------------
%% Copyright (c) 2018-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

%% MQTT/WS|WSS Connection
-module(emqx_ws_connection).

-include("emqx.hrl").
-include("emqx_mqtt.hrl").
-include("logger.hrl").
-include("types.hrl").


-ifdef(TEST).
-compile(export_all).
-compile(nowarn_export_all).
-endif.

%% API
-export([ info/1
        , stats/1
        ]).

-export([ call/2
        , call/3
        ]).

%% WebSocket callbacks
-export([ init/2
        , websocket_init/1
        , websocket_handle/2
        , websocket_info/2
        , websocket_close/2
        , terminate/3
        ]).

%% Export for CT
-export([set_field/3]).

-import(emqx_misc,
        [ maybe_apply/2
        , start_timer/2
        ]).

-record(state, {
          %% Peername of the ws connection
          peername :: emqx_types:peername(),
          %% Sockname of the ws connection
          sockname :: emqx_types:peername(),
          %% Sock state
          sockstate :: emqx_types:sockstate(),
          %% MQTT Piggyback
          mqtt_piggyback :: single | multiple,
          %% Limiter
          limiter :: maybe(emqx_limiter:limiter()),
          %% Limit Timer
          limit_timer :: maybe(reference()),
          %% Parse State
          parse_state :: emqx_frame:parse_state(),
          %% Serialize options
          serialize :: emqx_frame:serialize_opts(),
          %% Channel
          channel :: emqx_channel:channel(),
          %% GC State
          gc_state :: maybe(emqx_gc:gc_state()),
          %% Postponed Packets|Cmds|Events
          postponed :: list(emqx_types:packet()|ws_cmd()|tuple()),
          %% Stats Timer
          stats_timer :: disabled | maybe(reference()),
          %% Idle Timeout
          idle_timeout :: timeout(),
          %% Idle Timer
          idle_timer :: maybe(reference()),
          %% Zone name
          zone :: atom(),
          %% Listener Type and Name
          listener :: {Type::atom(), Name::atom()}
        }).

-type(state() :: #state{}).

-type(ws_cmd() :: {active, boolean()}|close).

-define(ACTIVE_N, 100).
-define(INFO_KEYS, [socktype, peername, sockname, sockstate]).
-define(SOCK_STATS, [recv_oct, recv_cnt, send_oct, send_cnt]).
-define(CONN_STATS, [recv_pkt, recv_msg, send_pkt, send_msg]).

-define(ENABLED(X), (X =/= undefined)).

-dialyzer({no_match, [info/2]}).
-dialyzer({nowarn_function, [websocket_init/1]}).

%%--------------------------------------------------------------------
%% Info, Stats
%%--------------------------------------------------------------------

-spec(info(pid()|state()) -> emqx_types:infos()).
info(WsPid) when is_pid(WsPid) ->
    call(WsPid, info);
info(State = #state{channel = Channel}) ->
    ChanInfo = emqx_channel:info(Channel),
    SockInfo = maps:from_list(
                 info(?INFO_KEYS, State)),
    ChanInfo#{sockinfo => SockInfo}.

info(Keys, State) when is_list(Keys) ->
    [{Key, info(Key, State)} || Key <- Keys];
info(socktype, _State) -> ws;
info(peername, #state{peername = Peername}) ->
    Peername;
info(sockname, #state{sockname = Sockname}) ->
    Sockname;
info(sockstate, #state{sockstate = SockSt}) ->
    SockSt;
info(limiter, #state{limiter = Limiter}) ->
    maybe_apply(fun emqx_limiter:info/1, Limiter);
info(channel, #state{channel = Channel}) ->
    emqx_channel:info(Channel);
info(gc_state, #state{gc_state = GcSt}) ->
    maybe_apply(fun emqx_gc:info/1, GcSt);
info(postponed, #state{postponed = Postponed}) ->
    Postponed;
info(stats_timer, #state{stats_timer = TRef}) ->
    TRef;
info(idle_timeout, #state{idle_timeout = Timeout}) ->
    Timeout;
info(idle_timer, #state{idle_timer = TRef}) ->
    TRef.

-spec(stats(pid()|state()) -> emqx_types:stats()).
stats(WsPid) when is_pid(WsPid) ->
    call(WsPid, stats);
stats(#state{channel = Channel}) ->
    SockStats = emqx_pd:get_counters(?SOCK_STATS),
    ConnStats = emqx_pd:get_counters(?CONN_STATS),
    ChanStats = emqx_channel:stats(Channel),
    ProcStats = emqx_misc:proc_stats(),
    lists:append([SockStats, ConnStats, ChanStats, ProcStats]).

%% kick|discard|takeover
-spec(call(pid(), Req :: term()) -> Reply :: term()).
call(WsPid, Req) ->
    call(WsPid, Req, 5000).

call(WsPid, Req, Timeout) when is_pid(WsPid) ->
    Mref = erlang:monitor(process, WsPid),
    WsPid ! {call, {self(), Mref}, Req},
    receive
        {Mref, Reply} ->
            erlang:demonitor(Mref, [flush]),
            Reply;
        {'DOWN', Mref, _, _, Reason} ->
            exit(Reason)
    after Timeout ->
        erlang:demonitor(Mref, [flush]),
        exit(timeout)
    end.

%%--------------------------------------------------------------------
%% WebSocket callbacks
%%--------------------------------------------------------------------

init(Req, #{listener := {Type, Listener}} = Opts) ->
    %% WS Transport Idle Timeout
    WsOpts = #{compress => get_ws_opts(Type, Listener, compress),
               deflate_opts => get_ws_opts(Type, Listener, deflate_opts),
               max_frame_size => get_ws_opts(Type, Listener, max_frame_size),
               idle_timeout => get_ws_opts(Type, Listener, idle_timeout)
              },
    case check_origin_header(Req, Opts) of
        {error, Reason} ->
            ?SLOG(error, #{msg => "invalid_origin_header", reason => Reason}),
            {ok, cowboy_req:reply(403, Req), WsOpts};
        ok ->
            parse_sec_websocket_protocol(Req, Opts, WsOpts)
    end.

parse_sec_websocket_protocol(Req, #{listener := {Type, Listener}} = Opts, WsOpts) ->
    case cowboy_req:parse_header(<<"sec-websocket-protocol">>, Req) of
        undefined ->
            case get_ws_opts(Type, Listener, fail_if_no_subprotocol) of
                true ->
                    {ok, cowboy_req:reply(400, Req), WsOpts};
                false ->
                    {cowboy_websocket, Req, [Req, Opts], WsOpts}
            end;
        Subprotocols ->
            SupportedSubprotocols = get_ws_opts(Type, Listener, supported_subprotocols),
            NSupportedSubprotocols = [list_to_binary(Subprotocol)
                                      || Subprotocol <- SupportedSubprotocols],
            case pick_subprotocol(Subprotocols, NSupportedSubprotocols) of
                {ok, Subprotocol} ->
                    Resp = cowboy_req:set_resp_header(<<"sec-websocket-protocol">>,
                                                      Subprotocol,
                                                      Req),
                    {cowboy_websocket, Resp, [Req, Opts], WsOpts};
                {error, no_supported_subprotocol} ->
                    {ok, cowboy_req:reply(400, Req), WsOpts}
            end
    end.

pick_subprotocol([], _SupportedSubprotocols) ->
    {error, no_supported_subprotocol};
pick_subprotocol([Subprotocol | Rest], SupportedSubprotocols) ->
    case lists:member(Subprotocol, SupportedSubprotocols) of
        true ->
            {ok, Subprotocol};
        false ->
            pick_subprotocol(Rest, SupportedSubprotocols)
    end.

parse_header_fun_origin(Req, #{listener := {Type, Listener}}) ->
    case cowboy_req:header(<<"origin">>, Req) of
        undefined ->
                case get_ws_opts(Type, Listener, allow_origin_absence) of
                    true -> ok;
                    false -> {error, origin_header_cannot_be_absent}
                end;
        Value ->
            case lists:member(Value, get_ws_opts(Type, Listener, check_origins)) of
                true -> ok;
                false -> {error, #{bad_origin => Value}}
            end
    end.

check_origin_header(Req, #{listener := {Type, Listener}} = Opts) ->
    case get_ws_opts(Type, Listener, check_origin_enable) of
        true -> parse_header_fun_origin(Req, Opts);
        false -> ok
    end.

websocket_init([Req, #{zone := Zone, listener := {Type, Listener}} = Opts]) ->
    {Peername, Peercert} =
        case emqx_config:get_listener_conf(Type, Listener, [proxy_protocol]) andalso
             maps:get(proxy_header, Req) of
            #{src_address := SrcAddr, src_port := SrcPort, ssl := SSL} ->
                SourceName = {SrcAddr, SrcPort},
                %% Notice: Only CN is available in Proxy Protocol V2 additional info
                SourceSSL = case maps:get(cn, SSL, undefined) of
                             undeined -> nossl;
                             CN -> [{pp2_ssl_cn, CN}]
                           end,
                {SourceName, SourceSSL};
            #{src_address := SrcAddr, src_port := SrcPort} ->
                SourceName = {SrcAddr, SrcPort},
                {SourceName, nossl};
            _ ->
                {get_peer(Req, Opts), cowboy_req:cert(Req)}
        end,
    Sockname = cowboy_req:sock(Req),
    WsCookie = try cowboy_req:parse_cookies(Req)
               catch
                   error:badarg ->
                       ?SLOG(error, #{msg => "bad_cookie"}),
                       undefined;
                   Error:Reason ->
                       ?SLOG(error, #{msg => "failed_to_parse_cookie",
                                      exception => Error,
                                      reason => Reason}),
                       undefined
               end,
    ConnInfo = #{socktype  => ws,
                 peername  => Peername,
                 sockname  => Sockname,
                 peercert  => Peercert,
                 ws_cookie => WsCookie,
                 conn_mod  => ?MODULE
                },
    Limiter = emqx_limiter:init(Zone, undefined, undefined, []),
    MQTTPiggyback = get_ws_opts(Type, Listener, mqtt_piggyback),
    FrameOpts = #{
        strict_mode => emqx_config:get_zone_conf(Zone, [mqtt, strict_mode]),
        max_size => emqx_config:get_zone_conf(Zone, [mqtt, max_packet_size])
    },
    ParseState = emqx_frame:initial_parse_state(FrameOpts),
    Serialize = emqx_frame:serialize_opts(),
    Channel = emqx_channel:init(ConnInfo, Opts),
    GcState = case emqx_config:get_zone_conf(Zone, [force_gc]) of
        #{enable := false} -> undefined;
        GcPolicy -> emqx_gc:init(GcPolicy)
    end,
    StatsTimer = case emqx_config:get_zone_conf(Zone, [stats, enable]) of
        true -> undefined;
        false -> disabled
    end,
    %% MQTT Idle Timeout
    IdleTimeout = emqx_channel:get_mqtt_conf(Zone, idle_timeout),
    IdleTimer = start_timer(IdleTimeout, idle_timeout),
    case emqx_config:get_zone_conf(emqx_channel:info(zone, Channel),
            [force_shutdown]) of
        #{enable := false} -> ok;
        ShutdownPolicy -> emqx_misc:tune_heap_size(ShutdownPolicy)
    end,
    emqx_logger:set_metadata_peername(esockd:format(Peername)),
    {ok, #state{peername       = Peername,
                sockname       = Sockname,
                sockstate      = running,
                mqtt_piggyback = MQTTPiggyback,
                limiter        = Limiter,
                parse_state    = ParseState,
                serialize      = Serialize,
                channel        = Channel,
                gc_state       = GcState,
                postponed      = [],
                stats_timer    = StatsTimer,
                idle_timeout   = IdleTimeout,
                idle_timer     = IdleTimer,
                zone           = Zone,
                listener       = {Type, Listener}
               }, hibernate}.

websocket_handle({binary, Data}, State) when is_list(Data) ->
    websocket_handle({binary, iolist_to_binary(Data)}, State);

websocket_handle({binary, Data}, State) ->
    ?SLOG(debug, #{msg => "RECV_data", data => Data, transport => websocket}),
    ok = inc_recv_stats(1, iolist_size(Data)),
    NState = ensure_stats_timer(State),
    return(parse_incoming(Data, NState));

%% Pings should be replied with pongs, cowboy does it automatically
%% Pongs can be safely ignored. Clause here simply prevents crash.
websocket_handle(Frame, State) when Frame =:= ping; Frame =:= pong ->
    return(State);

websocket_handle({Frame, _}, State) when Frame =:= ping; Frame =:= pong ->
    return(State);

websocket_handle({Frame, _}, State) ->
    %% TODO: should not close the ws connection
    ?SLOG(error, #{msg => "unexpected_frame", frame => Frame}),
    shutdown(unexpected_ws_frame, State).

websocket_info({call, From, Req}, State) ->
    handle_call(From, Req, State);

websocket_info({cast, rate_limit}, State) ->
    Stats = #{cnt => emqx_pd:reset_counter(incoming_pubs),
              oct => emqx_pd:reset_counter(incoming_bytes)
             },
    NState = postpone({check_gc, Stats}, State),
    return(ensure_rate_limit(Stats, NState));

websocket_info({cast, Msg}, State) ->
    handle_info(Msg, State);

websocket_info({incoming, Packet = ?CONNECT_PACKET(ConnPkt)}, State) ->
    Serialize = emqx_frame:serialize_opts(ConnPkt),
    NState = State#state{serialize = Serialize},
    handle_incoming(Packet, cancel_idle_timer(NState));

websocket_info({incoming, Packet}, State) ->
    handle_incoming(Packet, State);

websocket_info({outgoing, Packets}, State) ->
    return(enqueue(Packets, State));

websocket_info({check_gc, Stats}, State) ->
    return(check_oom(run_gc(Stats, State)));

websocket_info(Deliver = {deliver, _Topic, _Msg},
               State = #state{listener = {Type, Listener}}) ->
    ActiveN = get_active_n(Type, Listener),
    Delivers = [Deliver|emqx_misc:drain_deliver(ActiveN)],
    with_channel(handle_deliver, [Delivers], State);

websocket_info({timeout, TRef, limit_timeout},
               State = #state{limit_timer = TRef}) ->
    NState = State#state{sockstate   = running,
                         limit_timer = undefined
                        },
    return(enqueue({active, true}, NState));

websocket_info({timeout, TRef, Msg}, State) when is_reference(TRef) ->
    handle_timeout(TRef, Msg, State);

websocket_info({shutdown, Reason}, State) ->
    shutdown(Reason, State);

websocket_info({stop, Reason}, State) ->
    shutdown(Reason, State);

websocket_info(Info, State) ->
    handle_info(Info, State).

websocket_close({_, ReasonCode, _Payload}, State) when is_integer(ReasonCode) ->
    websocket_close(ReasonCode, State);
websocket_close(Reason, State) ->
    ?SLOG(debug, #{msg => "websocket_closed", reason => Reason}),
    handle_info({sock_closed, Reason}, State).

terminate(Reason, _Req, #state{channel = Channel}) ->
    ?SLOG(debug, #{msg => "terminated", reason => Reason}),
    emqx_channel:terminate(Reason, Channel);

terminate(_Reason, _Req, _UnExpectedState) ->
    ok.

%%--------------------------------------------------------------------
%% Handle call
%%--------------------------------------------------------------------

handle_call(From, info, State) ->
    gen_server:reply(From, info(State)),
    return(State);

handle_call(From, stats, State) ->
    gen_server:reply(From, stats(State)),
    return(State);

handle_call(_From, {ratelimit, Policy}, State = #state{channel = Channel}) ->
    Zone = emqx_channel:info(zone, Channel),
    Limiter = emqx_limiter:init(Zone, Policy),
    {reply, ok, State#state{limiter = Limiter}};

handle_call(From, Req, State = #state{channel = Channel}) ->
    case emqx_channel:handle_call(Req, Channel) of
        {reply, Reply, NChannel} ->
            gen_server:reply(From, Reply),
            return(State#state{channel = NChannel});
        {shutdown, Reason, Reply, NChannel} ->
            gen_server:reply(From, Reply),
            shutdown(Reason, State#state{channel = NChannel});
        {shutdown, Reason, Reply, Packet, NChannel} ->
            gen_server:reply(From, Reply),
            NState = State#state{channel = NChannel},
            shutdown(Reason, enqueue(Packet, NState))
    end.

%%--------------------------------------------------------------------
%% Handle Info
%%--------------------------------------------------------------------

handle_info({connack, ConnAck}, State) ->
    return(enqueue(ConnAck, State));

handle_info({close, Reason}, State) ->
    ?SLOG(debug, #{msg => "force_socket_close", reason => Reason}),
    return(enqueue({close, Reason}, State));

handle_info({event, connected}, State = #state{channel = Channel}) ->
    ClientId = emqx_channel:info(clientid, Channel),
    emqx_cm:insert_channel_info(ClientId, info(State), stats(State)),
    return(State);

handle_info({event, disconnected}, State = #state{channel = Channel}) ->
    ClientId = emqx_channel:info(clientid, Channel),
    emqx_cm:set_chan_info(ClientId, info(State)),
    emqx_cm:connection_closed(ClientId),
    return(State);

handle_info({event, _Other}, State = #state{channel = Channel}) ->
    ClientId = emqx_channel:info(clientid, Channel),
    emqx_cm:set_chan_info(ClientId, info(State)),
    emqx_cm:set_chan_stats(ClientId, stats(State)),
    return(State);

handle_info(Info, State) ->
    with_channel(handle_info, [Info], State).

%%--------------------------------------------------------------------
%% Handle timeout
%%--------------------------------------------------------------------

handle_timeout(TRef, idle_timeout, State = #state{idle_timer = TRef}) ->
    shutdown(idle_timeout, State);

handle_timeout(TRef, keepalive, State) when is_reference(TRef) ->
    RecvOct = emqx_pd:get_counter(recv_oct),
    handle_timeout(TRef, {keepalive, RecvOct}, State);

handle_timeout(TRef, emit_stats, State = #state{channel = Channel,
                                                stats_timer = TRef}) ->
    ClientId = emqx_channel:info(clientid, Channel),
    emqx_cm:set_chan_stats(ClientId, stats(State)),
    return(State#state{stats_timer = undefined});

handle_timeout(TRef, TMsg, State) ->
    with_channel(handle_timeout, [TRef, TMsg], State).

%%--------------------------------------------------------------------
%% Ensure rate limit
%%--------------------------------------------------------------------

ensure_rate_limit(Stats, State = #state{limiter = Limiter}) ->
    case ?ENABLED(Limiter) andalso emqx_limiter:check(Stats, Limiter) of
        false -> State;
        {ok, Limiter1} ->
            State#state{limiter = Limiter1};
        {pause, Time, Limiter1} ->
            ?SLOG(warning, #{msg => "pause_due_to_rate_limit", time => Time}),
            TRef = start_timer(Time, limit_timeout),
            NState = State#state{sockstate   = blocked,
                                 limiter     = Limiter1,
                                 limit_timer = TRef
                                },
            enqueue({active, false}, NState)
    end.

%%--------------------------------------------------------------------
%% Run GC, Check OOM
%%--------------------------------------------------------------------

run_gc(Stats, State = #state{gc_state = GcSt}) ->
    case ?ENABLED(GcSt) andalso emqx_gc:run(Stats, GcSt) of
        false -> State;
        {_IsGC, GcSt1} ->
            State#state{gc_state = GcSt1}
    end.

check_oom(State = #state{channel = Channel}) ->
    ShutdownPolicy = emqx_config:get_zone_conf(
        emqx_channel:info(zone, Channel), [force_shutdown]),
    case ShutdownPolicy of
        #{enable := false} -> State;
        #{enable := true} ->
            case emqx_misc:check_oom(ShutdownPolicy) of
                Shutdown = {shutdown, _Reason} ->
                    postpone(Shutdown, State);
                _Other -> State
            end
    end.

%%--------------------------------------------------------------------
%% Parse incoming data
%%--------------------------------------------------------------------

parse_incoming(<<>>, State) ->
    State;

parse_incoming(Data, State = #state{parse_state = ParseState}) ->
    try emqx_frame:parse(Data, ParseState) of
        {more, NParseState} ->
            State#state{parse_state = NParseState};
        {ok, Packet, Rest, NParseState} ->
            NState = State#state{parse_state = NParseState},
            parse_incoming(Rest, postpone({incoming, Packet}, NState))
    catch
        throw : ?FRAME_PARSE_ERROR(Reason) ->
            ?SLOG(info, #{ reason => Reason
                         , at_state => emqx_frame:describe_state(ParseState)
                         , input_bytes => Data
                         }),
            FrameError = {frame_error, Reason},
            postpone({incoming, FrameError}, State);
        error : Reason : Stacktrace ->
            ?SLOG(error, #{ at_state => emqx_frame:describe_state(ParseState)
                          , input_bytes => Data
                          , exception => Reason
                          , stacktrace => Stacktrace
                          }),
            FrameError = {frame_error, Reason},
            postpone({incoming, FrameError}, State)
    end.

%%--------------------------------------------------------------------
%% Handle incoming packet
%%--------------------------------------------------------------------

handle_incoming(Packet, State = #state{listener = {Type, Listener}})
  when is_record(Packet, mqtt_packet) ->
    ?SLOG(debug, #{msg => "RECV", packet => emqx_packet:format(Packet)}),
    ok = inc_incoming_stats(Packet),
    NState = case emqx_pd:get_counter(incoming_pubs) >
                  get_active_n(Type, Listener) of
                 true  -> postpone({cast, rate_limit}, State);
                 false -> State
             end,
    with_channel(handle_in, [Packet], NState);

handle_incoming(FrameError, State) ->
    with_channel(handle_in, [FrameError], State).

%%--------------------------------------------------------------------
%% With Channel
%%--------------------------------------------------------------------

with_channel(Fun, Args, State = #state{channel = Channel}) ->
    case erlang:apply(emqx_channel, Fun, Args ++ [Channel]) of
        ok -> return(State);
        {ok, NChannel} ->
            return(State#state{channel = NChannel});
        {ok, Replies, NChannel} ->
            return(postpone(Replies, State#state{channel= NChannel}));
        {shutdown, Reason, NChannel} ->
            shutdown(Reason, State#state{channel = NChannel});
        {shutdown, Reason, Packet, NChannel} ->
            NState = State#state{channel = NChannel},
            shutdown(Reason, postpone(Packet, NState))
    end.

%%--------------------------------------------------------------------
%% Handle outgoing packets
%%--------------------------------------------------------------------

handle_outgoing(Packets, State = #state{mqtt_piggyback = MQTTPiggyback,
        listener = {Type, Listener}}) ->
    IoData = lists:map(serialize_and_inc_stats_fun(State), Packets),
    Oct = iolist_size(IoData),
    ok = inc_sent_stats(length(Packets), Oct),
    NState = case emqx_pd:get_counter(outgoing_pubs) >
                  get_active_n(Type, Listener) of
                 true ->
                     Stats = #{cnt => emqx_pd:reset_counter(outgoing_pubs),
                               oct => emqx_pd:reset_counter(outgoing_bytes)
                              },
                     postpone({check_gc, Stats}, State);
                 false -> State
             end,

    {case MQTTPiggyback of
         single -> [{binary, IoData}];
         multiple -> lists:map(fun(Bin) -> {binary, Bin} end, IoData)
     end,
     ensure_stats_timer(NState)}.

serialize_and_inc_stats_fun(#state{serialize = Serialize}) ->
    fun(Packet) ->
        try emqx_frame:serialize_pkt(Packet, Serialize) of
            <<>> -> ?SLOG(warning, #{msg => "packet_discarded",
                                     reason => "frame_too_large",
                                     packet => emqx_packet:format(Packet)}),
                    ok = emqx_metrics:inc('delivery.dropped.too_large'),
                    ok = emqx_metrics:inc('delivery.dropped'),
                    <<>>;
            Data -> ?SLOG(debug, #{msg => "SEND", packet => Packet}),
                    ok = inc_outgoing_stats(Packet),
                    Data
        catch
            %% Maybe Never happen.
            throw : ?FRAME_SERIALIZE_ERROR(Reason) ->
                ?SLOG(info, #{ reason => Reason
                             , input_packet => Packet}),
                erlang:error(?FRAME_SERIALIZE_ERROR(Reason));
            error : Reason : Stacktrace ->
                ?SLOG(error, #{ input_packet => Packet
                              , exception => Reason
                              , stacktrace => Stacktrace}),
                erlang:error(frame_serialize_error)
        end
    end.

%%--------------------------------------------------------------------
%% Inc incoming/outgoing stats
%%--------------------------------------------------------------------

-compile({inline,
          [ inc_recv_stats/2
          , inc_incoming_stats/1
          , inc_outgoing_stats/1
          , inc_sent_stats/2
          ]}).

inc_recv_stats(Cnt, Oct) ->
    inc_counter(incoming_bytes, Oct),
    inc_counter(recv_cnt, Cnt),
    inc_counter(recv_oct, Oct),
    emqx_metrics:inc('bytes.received', Oct).

inc_incoming_stats(Packet = ?PACKET(Type)) ->
    _ = emqx_pd:inc_counter(recv_pkt, 1),
    if Type == ?PUBLISH ->
           inc_counter(recv_msg, 1),
           inc_counter(incoming_pubs, 1);
       true -> ok
    end,
    emqx_metrics:inc_recv(Packet).

inc_outgoing_stats(Packet = ?PACKET(Type)) ->
    _ = emqx_pd:inc_counter(send_pkt, 1),
    if Type == ?PUBLISH ->
           inc_counter(send_msg, 1),
           inc_counter(outgoing_pubs, 1);
       true -> ok
    end,
    emqx_metrics:inc_sent(Packet).

inc_sent_stats(Cnt, Oct) ->
    inc_counter(outgoing_bytes, Oct),
    inc_counter(send_cnt, Cnt),
    inc_counter(send_oct, Oct),
    emqx_metrics:inc('bytes.sent', Oct).

inc_counter(Name, Value) ->
    _ = emqx_pd:inc_counter(Name, Value),
    ok.
%%--------------------------------------------------------------------
%% Helper functions
%%--------------------------------------------------------------------

-compile({inline, [cancel_idle_timer/1, ensure_stats_timer/1]}).

%%--------------------------------------------------------------------
%% Cancel idle timer

cancel_idle_timer(State = #state{idle_timer = IdleTimer}) ->
    ok = emqx_misc:cancel_timer(IdleTimer),
    State#state{idle_timer = undefined}.

%%--------------------------------------------------------------------
%% Ensure stats timer

ensure_stats_timer(State = #state{idle_timeout = Timeout,
                                  stats_timer  = undefined}) ->
    State#state{stats_timer = start_timer(Timeout, emit_stats)};
ensure_stats_timer(State) -> State.

-compile({inline, [postpone/2, enqueue/2, return/1, shutdown/2]}).

%%--------------------------------------------------------------------
%% Postpone the packet, cmd or event

postpone(Packet, State) when is_record(Packet, mqtt_packet) ->
    enqueue(Packet, State);
postpone(Event, State) when is_tuple(Event) ->
    enqueue(Event, State);
postpone(More, State) when is_list(More) ->
    lists:foldl(fun postpone/2, State, More).

enqueue([Packet], State = #state{postponed = Postponed}) ->
    State#state{postponed = [Packet|Postponed]};
enqueue(Packets, State = #state{postponed = Postponed})
  when is_list(Packets) ->
    State#state{postponed = lists:reverse(Packets) ++ Postponed};
enqueue(Other, State = #state{postponed = Postponed}) ->
    State#state{postponed = [Other|Postponed]}.

shutdown(Reason, State = #state{postponed = Postponed}) ->
    return(State#state{postponed = [{shutdown, Reason}|Postponed]}).

return(State = #state{postponed = []}) ->
    {ok, State};
return(State = #state{postponed = Postponed}) ->
    {Packets, Cmds, Events} = classify(Postponed, [], [], []),
    ok = lists:foreach(fun trigger/1, Events),
    State1 = State#state{postponed = []},
    case {Packets, Cmds} of
        {[], []}   -> {ok, State1};
        {[], Cmds} -> {Cmds, State1};
        {Packets, Cmds} ->
            {Frames, State2} = handle_outgoing(Packets, State1),
            {Frames ++ Cmds, State2}
    end.

classify([], Packets, Cmds, Events) ->
    {Packets, Cmds, Events};
classify([Packet|More], Packets, Cmds, Events)
  when is_record(Packet, mqtt_packet) ->
    classify(More, [Packet|Packets], Cmds, Events);
classify([Cmd = {active, _}|More], Packets, Cmds, Events) ->
    classify(More, Packets, [Cmd|Cmds], Events);
classify([Cmd = {shutdown, _Reason}|More], Packets, Cmds, Events) ->
    classify(More, Packets, [Cmd|Cmds], Events);
classify([Cmd = close|More], Packets, Cmds, Events) ->
    classify(More, Packets, [Cmd|Cmds], Events);
classify([Cmd = {close, _Reason}|More], Packets, Cmds, Events) ->
    classify(More, Packets, [Cmd|Cmds], Events);
classify([Event|More], Packets, Cmds, Events) ->
    classify(More, Packets, Cmds, [Event|Events]).

trigger(Event) -> erlang:send(self(), Event).

get_peer(Req, #{listener := {Type, Listener}}) ->
    {PeerAddr, PeerPort} = cowboy_req:peer(Req),
    AddrHeader = cowboy_req:header(
        get_ws_opts(Type, Listener, proxy_address_header), Req, <<>>),
    ClientAddr = case string:tokens(binary_to_list(AddrHeader), ", ") of
                     [] ->
                         undefined;
                     AddrList ->
                         hd(AddrList)
                 end,
    Addr = case inet:parse_address(ClientAddr) of
               {ok, A} ->
                   A;
               _ ->
                   PeerAddr
           end,
    PortHeader = cowboy_req:header(
        get_ws_opts(Type, Listener, proxy_port_header), Req, <<>>),
    ClientPort = case string:tokens(binary_to_list(PortHeader), ", ") of
                     [] ->
                         undefined;
                     PortList ->
                         hd(PortList)
                 end,
    try
        {Addr, list_to_integer(ClientPort)}
    catch
        _:_  -> {Addr, PeerPort}
    end.

%%--------------------------------------------------------------------
%% For CT tests
%%--------------------------------------------------------------------

set_field(Name, Value, State) ->
    Pos = emqx_misc:index_of(Name, record_info(fields, state)),
    setelement(Pos+1, State, Value).

get_ws_opts(Type, Listener, Key) ->
    emqx_config:get_listener_conf(Type, Listener, [websocket, Key]).

get_active_n(Type, Listener) ->
    emqx_config:get_listener_conf(Type, Listener, [tcp, active_n]).
