%%--------------------------------------------------------------------
%% Copyright (c) 2017-2021 EMQ Technologies Co., Ltd. All Rights Reserved.
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

-module(emqx_misc).

-compile(inline).

-include("types.hrl").
-include("logger.hrl").

-export([ merge_opts/2
        , maybe_apply/2
        , compose/1
        , compose/2
        , run_fold/3
        , pipeline/3
        , start_timer/2
        , start_timer/3
        , cancel_timer/1
        , drain_deliver/0
        , drain_deliver/1
        , drain_down/1
        , check_oom/1
        , check_oom/2
        , tune_heap_size/1
        , proc_name/2
        , proc_stats/0
        , proc_stats/1
        , rand_seed/0
        , now_to_secs/1
        , now_to_ms/1
        , index_of/2
        , maybe_parse_ip/1
        , ipv6_probe/1
        , gen_id/0
        , gen_id/1
        ]).

-export([ bin2hexstr_A_F/1
        , bin2hexstr_a_f/1
        , hexstr2bin/1
        ]).

-define(SHORT, 8).

%% @doc Parse v4 or v6 string format address to tuple.
%% `Host' itself is returned if it's not an ip string.
maybe_parse_ip(Host) ->
    case inet:parse_address(Host) of
        {ok, Addr} when is_tuple(Addr) -> Addr;
        {error, einval} -> Host
    end.

%% @doc Add `ipv6_probe' socket option if it's supported.
ipv6_probe(Opts) ->
    case persistent_term:get({?MODULE, ipv6_probe_supported}, unknown) of
        unknown ->
            %% e.g. 23.2.7.1-emqx-2-x86_64-unknown-linux-gnu-64
            OtpVsn = emqx_vm:get_otp_version(),
            Bool = (match =:= re:run(OtpVsn, "emqx", [{capture, none}])),
            _ = persistent_term:put({?MODULE, ipv6_probe_supported}, Bool),
            ipv6_probe(Bool, Opts);
        Bool ->
            ipv6_probe(Bool, Opts)
    end.

ipv6_probe(false, Opts) -> Opts;
ipv6_probe(true, Opts) -> [{ipv6_probe, true} | Opts].

%% @doc Merge options
-spec(merge_opts(Opts, Opts) -> Opts when Opts :: proplists:proplist()).
merge_opts(Defaults, Options) ->
    lists:foldl(
      fun({Opt, Val}, Acc) ->
          lists:keystore(Opt, 1, Acc, {Opt, Val});
         (Opt, Acc) ->
          lists:usort([Opt | Acc])
      end, Defaults, Options).

%% @doc Apply a function to a maybe argument.
-spec(maybe_apply(fun((maybe(A)) -> maybe(A)), maybe(A))
      -> maybe(A) when A :: any()).
maybe_apply(_Fun, undefined) -> undefined;
maybe_apply(Fun, Arg) when is_function(Fun) ->
    erlang:apply(Fun, [Arg]).

-spec(compose(list(F)) -> G
  when F :: fun((any()) -> any()),
       G :: fun((any()) -> any())).
compose([F|More]) -> compose(F, More).

-spec(compose(F, G|[Gs]) -> C
  when F :: fun((X1) -> X2),
       G :: fun((X2) -> X3),
       Gs :: [fun((Xn) -> Xn1)],
       C :: fun((X1) -> Xm),
       X3 :: any(), Xn :: any(), Xn1 :: any(), Xm :: any()).
compose(F, G) when is_function(G) -> fun(X) -> G(F(X)) end;
compose(F, [G]) -> compose(F, G);
compose(F, [G|More]) -> compose(compose(F, G), More).

%% @doc RunFold
run_fold([], Acc, _State) ->
    Acc;
run_fold([Fun|More], Acc, State) ->
    run_fold(More, Fun(Acc, State), State).

%% @doc Pipeline
pipeline([], Input, State) ->
    {ok, Input, State};

pipeline([Fun|More], Input, State) ->
    case apply_fun(Fun, Input, State) of
        ok -> pipeline(More, Input, State);
        {ok, NState} ->
            pipeline(More, Input, NState);
        {ok, Output, NState} ->
            pipeline(More, Output, NState);
        {error, Reason} ->
            {error, Reason, State};
        {error, Reason, NState} ->
            {error, Reason, NState}
    end.

-compile({inline, [apply_fun/3]}).
apply_fun(Fun, Input, State) ->
    case erlang:fun_info(Fun, arity) of
        {arity, 1} -> Fun(Input);
        {arity, 2} -> Fun(Input, State)
    end.

-spec(start_timer(integer(), term()) -> reference()).
start_timer(Interval, Msg) ->
    start_timer(Interval, self(), Msg).

-spec(start_timer(integer(), pid() | atom(), term()) -> reference()).
start_timer(Interval, Dest, Msg) ->
    erlang:start_timer(erlang:ceil(Interval), Dest, Msg).

-spec(cancel_timer(maybe(reference())) -> ok).
cancel_timer(Timer) when is_reference(Timer) ->
    case erlang:cancel_timer(Timer) of
        false ->
            receive {timeout, Timer, _} -> ok after 0 -> ok end;
        _ -> ok
    end;
cancel_timer(_) -> ok.

%% @doc Drain delivers
drain_deliver() ->
    drain_deliver(-1).

drain_deliver(N) when is_integer(N) ->
    drain_deliver(N, []).

drain_deliver(0, Acc) ->
    lists:reverse(Acc);
drain_deliver(N, Acc) ->
    receive
        Deliver = {deliver, _Topic, _Msg} ->
            drain_deliver(N-1, [Deliver|Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

%% @doc Drain process 'DOWN' events.
-spec(drain_down(pos_integer()) -> list(pid())).
drain_down(Cnt) when Cnt > 0 ->
    drain_down(Cnt, []).

drain_down(0, Acc) ->
    lists:reverse(Acc);
drain_down(Cnt, Acc) ->
    receive
        {'DOWN', _MRef, process, Pid, _Reason} ->
            drain_down(Cnt-1, [Pid|Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

%% @doc Check process's mailbox and heapsize against OOM policy,
%% return `ok | {shutdown, Reason}' accordingly.
%% `ok': There is nothing out of the ordinary.
%% `shutdown': Some numbers (message queue length hit the limit),
%%             hence shutdown for greater good (system stability).
-spec(check_oom(emqx_types:oom_policy()) -> ok | {shutdown, term()}).
check_oom(Policy) ->
    check_oom(self(), Policy).

-spec(check_oom(pid(), emqx_types:oom_policy()) -> ok | {shutdown, term()}).
check_oom(_Pid, #{enable := false}) -> ok;
check_oom(Pid, #{max_message_queue_len := MaxQLen,
                 max_heap_size := MaxHeapSize}) ->
    case process_info(Pid, [message_queue_len, total_heap_size]) of
        undefined -> ok;
        [{message_queue_len, QLen}, {total_heap_size, HeapSize}] ->
            do_check_oom([{QLen, MaxQLen, message_queue_too_long},
                          {HeapSize, MaxHeapSize, proc_heap_too_large}
                         ])
    end.

do_check_oom([]) -> ok;
do_check_oom([{Val, Max, Reason}|Rest]) ->
    case is_integer(Max) andalso (0 < Max) andalso (Max < Val) of
        true  -> {shutdown, Reason};
        false -> do_check_oom(Rest)
    end.

tune_heap_size(#{enable := false}) ->
    ok;
%% If the max_heap_size is set to zero, the limit is disabled.
tune_heap_size(#{max_heap_size := MaxHeapSize}) when MaxHeapSize > 0 ->
    MaxSize = case erlang:system_info(wordsize) of
        8 -> % arch_64
            (1 bsl 59) - 1;
        4 -> % arch_32
            (1 bsl 27) - 1
    end,
    OverflowedSize = case erlang:trunc(MaxHeapSize * 1.5) of
        SZ when SZ > MaxSize -> MaxSize;
        SZ -> SZ
    end,
    erlang:process_flag(max_heap_size, #{
        size => OverflowedSize,
        kill => true,
        error_logger => true
    }).


-spec(proc_name(atom(), pos_integer()) -> atom()).
proc_name(Mod, Id) ->
    list_to_atom(lists:concat([Mod, "_", Id])).

%% Get Proc's Stats.
-spec(proc_stats() -> emqx_types:stats()).
proc_stats() -> proc_stats(self()).

-spec(proc_stats(pid()) -> emqx_types:stats()).
proc_stats(Pid) ->
    case process_info(Pid, [message_queue_len,
                            heap_size,
                            total_heap_size,
                            reductions,
                            memory]) of
        undefined -> [];
        [{message_queue_len, Len}|ProcStats] ->
            [{mailbox_len, Len}|ProcStats]
    end.

rand_seed() ->
    rand:seed(exsplus, erlang:timestamp()).

-spec(now_to_secs(erlang:timestamp()) -> pos_integer()).
now_to_secs({MegaSecs, Secs, _MicroSecs}) ->
    MegaSecs * 1000000 + Secs.

-spec(now_to_ms(erlang:timestamp()) -> pos_integer()).
now_to_ms({MegaSecs, Secs, MicroSecs}) ->
    (MegaSecs * 1000000 + Secs) * 1000 + round(MicroSecs/1000).

%% lists:index_of/2
index_of(E, L) ->
    index_of(E, 1, L).

index_of(_E, _I, []) ->
    error(badarg);
index_of(E, I, [E|_]) ->
    I;
index_of(E, I, [_|L]) ->
    index_of(E, I+1, L).

-spec(bin2hexstr_A_F(binary()) -> binary()).
bin2hexstr_A_F(B) when is_binary(B) ->
    << <<(int2hexchar(H, upper)), (int2hexchar(L, upper))>> || <<H:4, L:4>> <= B>>.

-spec(bin2hexstr_a_f(binary()) -> binary()).
bin2hexstr_a_f(B) when is_binary(B) ->
    << <<(int2hexchar(H, lower)), (int2hexchar(L, lower))>> || <<H:4, L:4>> <= B>>.

int2hexchar(I, _) when I >= 0 andalso I < 10 -> I + $0;
int2hexchar(I, upper) -> I - 10 + $A;
int2hexchar(I, lower) -> I - 10 + $a.

-spec(hexstr2bin(binary()) -> binary()).
hexstr2bin(B) when is_binary(B) ->
    << <<(hexchar2int(H)*16 + hexchar2int(L))>> || <<H:8, L:8>> <= B>>.

hexchar2int(I) when I >= $0 andalso I =< $9 -> I - $0;
hexchar2int(I) when I >= $A andalso I =< $F -> I - $A + 10;
hexchar2int(I) when I >= $a andalso I =< $f -> I - $a + 10.

-spec(gen_id() -> list()).
gen_id() ->
    gen_id(?SHORT).

-spec(gen_id(integer()) -> list()).
gen_id(Len) ->
    BitLen = Len * 4,
    <<R:BitLen>> = crypto:strong_rand_bytes(Len div 2),
    int_to_hex(R, Len).

%%------------------------------------------------------------------------------
%% Internal Functions
%%------------------------------------------------------------------------------

int_to_hex(I, N) when is_integer(I), I >= 0 ->
    int_to_hex([], I, 1, N).

int_to_hex(L, I, Count, N)
    when I < 16 ->
    pad([int_to_hex(I) | L], N - Count);
int_to_hex(L, I, Count, N) ->
    int_to_hex([int_to_hex(I rem 16) | L], I div 16, Count + 1, N).

int_to_hex(I) when 0 =< I, I =< 9 ->
    I + $0;
int_to_hex(I) when 10 =< I, I =< 15 ->
    (I - 10) + $a.

pad(L, 0) ->
    L;
pad(L, Count) ->
    pad([$0 | L], Count - 1).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

ipv6_probe_test() ->
    ?assertEqual([{ipv6_probe, true}], ipv6_probe([])).

-endif.
