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

-module(emqx_rule_sqltester).

-include("rule_engine.hrl").
-include_lib("emqx/include/logger.hrl").

-export([ test/1
        , echo_action/2
        , get_selected_data/3
        ]).

-spec test(#{sql := binary(), context := map()}) -> {ok, map() | list()} | {error, nomatch}.
test(#{sql := Sql, context := Context}) ->
    {ok, Select} = emqx_rule_sqlparser:parse(Sql),
    InTopic = maps:get(topic, Context, <<>>),
    EventTopics = emqx_rule_sqlparser:select_from(Select),
    case lists:all(fun is_publish_topic/1, EventTopics) of
        true ->
            %% test if the topic matches the topic filters in the rule
            case emqx_plugin_libs_rule:can_topic_match_oneof(InTopic, EventTopics) of
                true -> test_rule(Sql, Select, Context, EventTopics);
                false -> {error, nomatch}
            end;
        false ->
            %% the rule is for both publish and events, test it directly
            test_rule(Sql, Select, Context, EventTopics)
    end.

test_rule(Sql, Select, Context, EventTopics) ->
    RuleId = iolist_to_binary(["sql_tester:", emqx_misc:gen_id(16)]),
    ok = emqx_rule_metrics:create_rule_metrics(RuleId),
    Rule = #{
        id => RuleId,
        sql => Sql,
        from => EventTopics,
        outputs => [#{mod => ?MODULE, func => get_selected_data, args => #{}}],
        enabled => true,
        is_foreach => emqx_rule_sqlparser:select_is_foreach(Select),
        fields => emqx_rule_sqlparser:select_fields(Select),
        doeach => emqx_rule_sqlparser:select_doeach(Select),
        incase => emqx_rule_sqlparser:select_incase(Select),
        conditions => emqx_rule_sqlparser:select_where(Select),
        created_at => erlang:system_time(millisecond)
    },
    FullContext = fill_default_values(hd(EventTopics), emqx_rule_maps:atom_key_map(Context)),
    try
        emqx_rule_runtime:apply_rule(Rule, FullContext)
    of
        {ok, Data} -> {ok, flatten(Data)};
        {error, nomatch} -> {error, nomatch}
    after
        emqx_rule_metrics:clear_rule_metrics(RuleId)
    end.

get_selected_data(Selected, _Envs, _Args) ->
    Selected.

is_publish_topic(<<"$events/", _/binary>>) -> false;
is_publish_topic(_Topic) -> true.

flatten([]) -> [];
flatten([D1]) -> D1;
flatten([D1 | L]) when is_list(D1) ->
    D1 ++ flatten(L).

echo_action(Data, Envs) ->
    ?SLOG(debug, #{msg => "testing_rule_sql_ok", data => Data, envs => Envs}),
    Data.

fill_default_values(Event, Context) ->
    maps:merge(envs_examp(Event), Context).

envs_examp(<<"$events/", _/binary>> = EVENT_TOPIC) ->
    EventName = emqx_rule_events:event_name(EVENT_TOPIC),
    emqx_rule_maps:atom_key_map(
        maps:from_list(
            emqx_rule_events:columns_with_exam(EventName)));
envs_examp(_) ->
    #{id => emqx_guid:to_hexstr(emqx_guid:gen()),
      clientid => <<"c_emqx">>,
      username => <<"u_emqx">>,
      payload => <<"{\"id\": 1, \"name\": \"ha\"}">>,
      peerhost => <<"127.0.0.1">>,
      topic => <<"t/a">>,
      qos => 1,
      flags => #{sys => true, event => true},
      publish_received_at => emqx_plugin_libs_rule:now_ms(),
      timestamp => emqx_plugin_libs_rule:now_ms(),
      node => node()
    }.
