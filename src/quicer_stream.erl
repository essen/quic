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
-module(quicer_stream).
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include("quicer_types.hrl").
-behaviour(gen_server).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%  Stream Callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-callback start_completed(stream_handle(), stream_start_completed_props(), cb_state()) -> cb_ret().
%% Handle local initiated stream start completed

-callback send_complete(stream_handle(), IsCanceled::boolean(), cb_state()) -> cb_ret().
%% Handle send completed.

-callback peer_send_shutdown(stream_handle(), error_code(), cb_state()) -> cb_ret().
%% Handle stream peer_send_shutdown.

-callback peer_send_aborted(stream_handle(), error_code(), cb_state()) -> cb_ret().
%% Handle stream peer_send_aborted.

-callback peer_receive_aborted(stream_handle(), error_code(), cb_state()) -> cb_ret().
%% Handle stream peer_receive_aborted

-callback send_shutdown_complete(stream_handle(), error_code(), cb_state()) -> cb_ret().
%% Handle stream send_shutdown_complete.
%% Happen immediately on an abortive send or after a graceful send has been acknowledged by the peer.

-callback stream_closed(stream_handle(), stream_closed_props(), cb_state()) -> cb_ret().
%% Handle stream closed, Both endpoints of sending and receiving of the stream have been shut down.

-callback peer_accepted(connection_handle(), stream_handle(), cb_state()) -> cb_ret().
%% Handle stream 'peer_accepted'.
%% The stream which **was not accepted** due to peer flow control is now accepted by the peer.

-callback passive(stream_handle(), undefined, cb_state()) -> cb_ret().
%% Stream now in 'passive' mode.

-type cb_state() :: any().

-type cb_ret() :: {ok, cb_state()}                    %% ok and update cb_state
                | {error, Reason::term(), cb_state()} %% error handling per callback
                | {hibernate, cb_state()}           %% ok but also hibernate process
                | {{continue, Continue :: term()}, cb_state()}  %% split callback work with Continue
                | {timeout(), cb_state()}           %% ok but also hibernate process
                | {stop, Reason :: term(), cb_state()}.            %% terminate with reason

%% API
-export([ %% Start before conn handshake, with only Conn handle
          start_link/2
          %% Start after conn handshake with new Stream Handle
        , start_link/3
        ]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         handle_continue/2,
         terminate/2, code_change/3, format_status/2]).

-define(SERVER, ?MODULE).
-define(post_init, post_init).

-type state() :: #{ stream := quicer:stream_handle()
                  , conn := quicer:connection_handle()
                  , callback := atom()
                  , callback_state := term()
                  , is_owner := boolean()
                  , stream_opts := map()
                  , is_resumed := boolean()
                  }.

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%% @end
%%--------------------------------------------------------------------
-spec start_link(Conn :: quicer:connection_handle(),
                 Stream_Opts :: map()) -> {ok, Pid :: pid()} |
          {error, Error :: {already_started, pid()}} |
          {error, Error :: term()} |
          ignore.
start_link(Conn, Stream_Opts) ->
    gen_server:start_link(?MODULE, [Conn, Stream_Opts], []).

-spec start_link(Stream :: quicer:connection_handle(),
                 Conn :: quicer:connection_handle(),
                 Stream_Opts :: map()) -> {ok, Pid :: pid()} |
          {error, Error :: {already_started, pid()}} |
          {error, Error :: term()} |
          ignore.
start_link(Stream, Conn, Stream_Opts) ->
    gen_server:start_link(?MODULE, [Stream, Conn, Stream_Opts], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%% @end
%%--------------------------------------------------------------------
-spec init(Args :: term()) -> {ok, state()} |
          {ok, state(), Timeout :: timeout()} |
          {ok, state(), hibernate} |
          {stop, Reason :: term()} |
          ignore.
%% Before conn handshake, with only Conn handle
init([Conn, StreamOpts]) when is_list(StreamOpts) ->
    init([Conn, maps:from_list(StreamOpts)]);
init([Conn, #{stream_callback := Callback} = StreamOpts]) ->
    process_flag(trap_exit, true),
    {ok, Conn} = quicer:async_accept_stream(Conn, StreamOpts),
    {ok, #{ is_owner => true
          , stream_opts => StreamOpts
          , conn => Conn
          , stream => undefined
          , callback => Callback
          , callback_state => undefined
          }};


%% After conn handshake, with stream handle
init([Stream, Conn, StreamOpts]) when is_list(StreamOpts) ->
    ?tp(new_stream_2, #{module=>?MODULE, stream=>Stream}),
    init([Stream, Conn, maps:from_list(StreamOpts)]);
init([Stream, Conn, #{stream_callback := CallbackModule} = StreamOpts]) ->
    ?tp(new_stream_3, #{module=>?MODULE, stream=>Stream}),
    process_flag(trap_exit, true),
    case CallbackModule:new_stream(Stream, StreamOpts) of
        {ok, CallbackState} ->
            State = #{ is_owner => false
                     , stream_opts => StreamOpts
                     , conn => Conn
                     , stream => Stream
                     , callback => CallbackModule
                     , callback_state => CallbackState
                     },
            %% handoff must be done for now
            {ok,  State, {continue , ?post_init}};
        {error, Reason} ->
            {stop , Reason}
    end.
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%% @end
%%--------------------------------------------------------------------
-spec handle_call(Request :: term(), From :: {pid(), term()}, state()) ->
          {reply, Reply :: term(), state()} |
          {reply, Reply :: term(), state(), Timeout :: timeout()} |
          {reply, Reply :: term(), state(), hibernate} |
          {noreply, state()} |
          {noreply, state(), Timeout :: timeout()} |
          {noreply, state(), hibernate} |
          {stop, Reason :: term(), Reply :: term(), state()} |
          {stop, Reason :: term(), state()}.
handle_call(Request, _From,
            #{stream := Stream,
              stream_opts := Options, callback_state := CallbackState} = State) ->
    #{stream_callback := CallbackModule} = Options,
    try CallbackModule:handle_call(Stream, Request, Options, CallbackState) of
        {ok, Reply, NewCallbackState} ->
            {reply, Reply, State#{ callback_state => NewCallbackState
                                 , stream_opts => Options
                                 }}
    catch _:Reason:ST ->
            maybe_log_stracetrace(ST),
            {reply, {callback_error, Reason}, State}
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_cast(Request :: term(), state()) ->
          {noreply, state()} |
          {noreply, state(), Timeout :: timeout()} |
          {noreply, state(), hibernate} |
          {stop, Reason :: term(), state()}.
handle_cast(_Request, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%% @end
%%--------------------------------------------------------------------
-spec handle_info(Info :: timeout() | term(), state()) ->
          {noreply, state()} |
          {noreply, state(), Timeout :: timeout()} |
          {noreply, state(), hibernate} |
          {stop, Reason :: normal | term(), state()}.
handle_info({quic, new_stream, Stream, Flags},
            #{stream_opts := Options, stream := undefined, callback := CallbackModule} = State) ->
    ?tp(new_stream, #{module=>?MODULE, stream=>Stream, stream_flags => Flags}),
    try CallbackModule:new_stream(Stream, Options#{open_flags => Flags}) of
        {ok, CallbackState} ->
            {noreply, State#{stream => Stream, callback_state => CallbackState}};
        {error, Reason} ->
            {stop, Reason, State#{stream => Stream}}
    catch
        _:Reason:ST ->
            maybe_log_stracetrace(ST),
            {stop, {new_stream_crash, Reason}, State#{stream => Stream}}
    end;
handle_info({quic, Bin, Stream, #{flags := Flags}},
            #{stream := Stream, stream_opts := Options, callback_state := CallbackState}= State)
  when is_binary(Bin) ->
    ?tp(stream_data, #{module=>?MODULE, stream=>Stream}),
    #{stream_callback := CallbackModule} = Options,
    try CallbackModule:handle_stream_data(Stream, Bin, Options, CallbackState) of
        {ok, NewCallbackState} ->
            %% @todo this should be a configurable behavior
            is_fin(Flags) andalso CallbackModule:shutdown(Stream),
            {noreply, State#{callback_state => NewCallbackState}};
        {error, Reason, NewCallbackState} ->
            {noreply, Reason, State#{callback_state => NewCallbackState}}
    catch
        _:Reason:ST ->
            maybe_log_stracetrace(ST),
            {stop, {handle_stream_data_crash, Reason}, State}
    end;
handle_info({quic, _Event, _Stream, _Props} = Msg, State) ->
    quicer_conn_acceptor:handle_info(Msg, State).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This callback is optional, so callback modules need to export it only if they return one of the tuples containing {continue,Continue} from another callback. If such a {continue,_} tuple is used and the callback is not implemented, the process will exit with undef error.
-spec handle_continue(Continue::term(), State::term()) ->
          {noreply, state()} |
          {noreply, state(), Timeout :: timeout()} |
          {noreply, state(), hibernate} |
          {stop, Reason :: normal | term(), state()}.
handle_continue(?post_init, #{ is_owner := false, stream := Stream} = State) ->
    ?tp(debug, #{event=>?post_init, module=>?MODULE, stream=>Stream}),
    case wait_for_handoff() of
        undefined ->
            ?tp(debug, #{event=>post_init_undef , module=>?MODULE, stream=>Stream}),
            {noreply, State#{is_owner => true}};
        {BinList, Len, Flag} ->
            ?tp(debug, #{event=>post_init_data, module=>?MODULE, stream=>Stream}),
            %% @TODO first data from the stream, offset 0,
            Msg = {quic, iolist_to_binary(BinList), Stream,
                   #{absolute_offset => 0, len => Len, flags => Flag}},
            handle_info(Msg, State#{is_owner => true})
    end;
handle_continue(?post_init, #{ is_owner := true } = State) ->
    logger:error("post_init when is owner"),
    {stop, internal_error, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%% @end
%%--------------------------------------------------------------------
-spec terminate(Reason :: normal | shutdown | {shutdown, term()} | term(),
                state()) -> any().
terminate(Reason, _State) ->
    error_code(Reason),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%% @end
%%--------------------------------------------------------------------
-spec code_change(OldVsn :: term() | {down, term()},
                  state(),
                  Extra :: term()) -> {ok, NewState :: term()} |
          {error, Reason :: term()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called for changing the form and appearance
%% of gen_server status when it is returned from sys:get_status/1,2
%% or when it appears in termination error logs.
%% @end
%%--------------------------------------------------------------------
-spec format_status(Opt :: normal | terminate,
                    Status :: list()) -> Status :: term().
format_status(_Opt, Status) ->
    Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================
error_code(normal) ->
    'QUIC_ERROR_NO_ERROR';
error_code(shutdown) ->
    'QUIC_ERROR_NO_ERROR';
error_code(_) ->
    %% @todo mapping errors to error code
    %% for closing stream
    'QUIC_ERROR_INTERNAL_ERROR'.

maybe_log_stracetrace(ST) ->
    logger:error("~p~n", [ST]),
    ok.

-spec is_fin(integer()) ->  boolean().
is_fin(0) ->
    false;
is_fin(Flags) when is_integer(Flags) ->
    (1 bsl 1) band Flags =/= 0.

%% handoff must happen
wait_for_handoff() ->
    receive
        {stream_owner_handoff, _From, Msg} ->
            Msg
    end.
