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

-module(emqx_coap_api).

-behaviour(minirest_api).

-include_lib("emqx_gateway/src/coap/include/emqx_coap.hrl").

%% API
-export([api_spec/0]).

-export([request/2]).

-define(PREFIX, "/gateway/coap/:clientid").
-define(DEF_WAIT_TIME, 10).

-import(emqx_mgmt_util, [ schema/1
                        , schema/2
                        , object_schema/1
                        , object_schema/2
                        , error_schema/2
                        , properties/1]).

%%--------------------------------------------------------------------
%%  API
%%--------------------------------------------------------------------
api_spec() ->
    {[request_api()], []}.

request_api() ->
    Metadata = #{post => request_method_meta()},
    {?PREFIX ++ "/request", Metadata, request}.

request(post, #{body := Body, bindings := Bindings}) ->
    ClientId = maps:get(clientid, Bindings, undefined),

    Method = maps:get(<<"method">>, Body, <<"get">>),
    CT = maps:get(<<"content_type">>, Body, <<"text/plain">>),
    Token = maps:get(<<"token">>, Body, <<>>),
    Payload = maps:get(<<"payload">>, Body, <<>>),
    BinWaitTime = maps:get(<<"timeout">>, Body, <<"10s">>),
    {ok, WaitTime} = emqx_schema:to_duration_ms(BinWaitTime),
    Payload2 = parse_payload(CT, Payload),
    ReqType = erlang:binary_to_atom(Method),

    Msg = emqx_coap_message:request(con,
                                    ReqType, Payload2, #{content_format => CT}),

    Msg2 = Msg#coap_message{token = Token},

    case call_client(ClientId, Msg2, timer:seconds(WaitTime)) of
        timeout ->
            {504, #{code => 'CLIENT_NOT_RESPONSE'}};
        not_found ->
            {404, #{code => 'CLIENT_NOT_FOUND'}};
        Response ->
            {200, format_to_response(CT, Response)}
    end.

%%--------------------------------------------------------------------
%%  Internal functions
%%--------------------------------------------------------------------
request_parameters() ->
    [#{name => clientid,
       in => path,
       schema => #{type => string},
       required => true}].

request_properties() ->
    properties([ {token, string, "message token, can be empty"}
               , {method, string, "request method type", ["get", "put", "post", "delete"]}
               , {timeout, string, "timespan for response"}
               , {content_type, string, "payload type",
                  [<<"text/plain">>, <<"application/json">>, <<"application/octet-stream">>]}
               , {payload, string, "payload"}]).

coap_message_properties() ->
    properties([ {id, integer, "message id"}
               , {token, string, "message token, can be empty"}
               , {method, string, "response code"}
               , {payload, string, "payload"}]).

request_method_meta() ->
    #{description => <<"lookup matching messages">>,
      parameters => request_parameters(),
      'requestBody' =>  object_schema(request_properties(),
                                      <<"request payload, binary must encode by base64">>),
      responses => #{
                     <<"200">> => object_schema(coap_message_properties()),
                     <<"404">> => error_schema("client not found error", ['CLIENT_NOT_FOUND']),
                     <<"504">> => error_schema("timeout", ['CLIENT_NOT_RESPONSE'])
                    }}.


format_to_response(ContentType, #coap_message{id = Id,
                                              token = Token,
                                              method = Method,
                                              payload = Payload}) ->
    #{id => Id,
      token => Token,
      method => format_to_binary(Method),
      payload => format_payload(ContentType, Payload)}.

format_to_binary(Obj) ->
    erlang:list_to_binary(io_lib:format("~p", [Obj])).

format_payload(<<"application/octet-stream">>, Payload) ->
    base64:encode(Payload);

format_payload(_, Payload) ->
    Payload.

parse_payload(<<"application/octet-stream">>, Body) ->
    base64:decode(Body);

parse_payload(_, Body) ->
    Body.

call_client(ClientId, Msg, Timeout) ->
    case emqx_gateway_cm_registry:lookup_channels(coap, ClientId) of
        [Channel | _] ->
            RequestId = emqx_coap_channel:send_request(Channel, Msg),
            case gen_server:wait_response(RequestId, Timeout) of
             {reply, Reply} ->
                 Reply;
             _ ->
                 timeout
            end;
        _ ->
            not_found
    end.
