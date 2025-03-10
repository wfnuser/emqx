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

-module(emqx_authn_utils).

-export([ replace_placeholders/2
        , replace_placeholder/2
        , check_password/3
        , is_superuser/1
        , hash/4
        , gen_salt/0
        , bin/1
        ]).

%%------------------------------------------------------------------------------
%% APIs
%%------------------------------------------------------------------------------

replace_placeholders(PlaceHolders, Data) ->
    replace_placeholders(PlaceHolders, Data, []).

replace_placeholders([], _Credential, Acc) ->
    lists:reverse(Acc);
replace_placeholders([Placeholder | More], Credential, Acc) ->
    case replace_placeholder(Placeholder, Credential) of
        undefined ->
            error({cannot_get_variable, Placeholder});
        V ->
            replace_placeholders(More, Credential, [convert_to_sql_param(V) | Acc])
    end.

replace_placeholder(<<"${mqtt-username}">>, Credential) ->
    maps:get(username, Credential, undefined);
replace_placeholder(<<"${mqtt-clientid}">>, Credential) ->
    maps:get(clientid, Credential, undefined);
replace_placeholder(<<"${mqtt-password}">>, Credential) ->
    maps:get(password, Credential, undefined);
replace_placeholder(<<"${ip-address}">>, Credential) ->
    maps:get(peerhost, Credential, undefined);
replace_placeholder(<<"${cert-subject}">>, Credential) ->
    maps:get(dn, Credential, undefined);
replace_placeholder(<<"${cert-common-name}">>, Credential) ->
    maps:get(cn, Credential, undefined);
replace_placeholder(Constant, _) ->
    Constant.

check_password(undefined, _Selected, _State) ->
    {error, bad_username_or_password};
check_password(Password,
               #{<<"password_hash">> := Hash},
               #{password_hash_algorithm := bcrypt}) ->
    case {ok, to_list(Hash)} =:= bcrypt:hashpw(Password, Hash) of
        true -> ok;
        false -> {error, bad_username_or_password}
    end;
check_password(Password,
               #{<<"password_hash">> := Hash} = Selected,
               #{password_hash_algorithm := Algorithm,
                 salt_position := SaltPosition}) ->
    Salt = maps:get(<<"salt">>, Selected, <<>>),
    case Hash =:= hash(Algorithm, Password, Salt, SaltPosition) of
        true -> ok;
        false -> {error, bad_username_or_password}
    end.

is_superuser(Selected) ->
    #{is_superuser => maps:get(<<"is_superuser">>, Selected, false)}.

hash(Algorithm, Password, Salt, prefix) ->
    emqx_passwd:hash(Algorithm, <<Salt/binary, Password/binary>>);
hash(Algorithm, Password, Salt, suffix) ->
    emqx_passwd:hash(Algorithm, <<Password/binary, Salt/binary>>).

gen_salt() ->
    <<X:128/big-unsigned-integer>> = crypto:strong_rand_bytes(16),
    iolist_to_binary(io_lib:format("~32.16.0b", [X])).

bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
bin(L) when is_list(L) -> list_to_binary(L);
bin(X) -> X.

%%------------------------------------------------------------------------------
%% Internal functions
%%------------------------------------------------------------------------------

convert_to_sql_param(undefined) ->
    null;
convert_to_sql_param(V) ->
    bin(V).

to_list(L) when is_list(L) -> L;
to_list(L) when is_binary(L) -> binary_to_list(L);
to_list(X) -> X.
