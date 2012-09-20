%%%----------------------------------------------------------------------
%%% Copyright (c) 2012 Peter Lemenkov <lemenkov@gmail.com>
%%%
%%% All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without modification,
%%% are permitted provided that the following conditions are met:
%%%
%%% * Redistributions of source code must retain the above copyright notice, this
%%% list of conditions and the following disclaimer.
%%% * Redistributions in binary form must reproduce the above copyright notice,
%%% this list of conditions and the following disclaimer in the documentation
%%% and/or other materials provided with the distribution.
%%% * Neither the name of the authors nor the names of its contributors
%%% may be used to endorse or promote products derived from this software
%%% without specific prior written permission.
%%%
%%% THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ''AS IS'' AND ANY
%%% EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
%%% WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
%%% DISCLAIMED. IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE FOR ANY
%%% DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
%%% (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
%%% ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
%%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
%%% SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
%%%
%%%----------------------------------------------------------------------

-module(gen_rtp_phy).
-author('lemenkov@gmail.com').

-behaviour(gen_server).

-export([start/3]).
-export([start_link/3]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([code_change/3]).
-export([terminate/2]).

-include("../include/rtcp.hrl").
-include("../include/rtp.hrl").
-include("../include/srtp.hrl").
-include("../include/stun.hrl").
-include("../include/zrtp.hrl").

% Default value of RTP timeout in milliseconds.
-define(INTERIM_UPDATE, 30000).

-record(state, {
		parent = null,
		rtp,
		rtcp,
		ip = null,
		rtpport = null,
		rtcpport = null,
		tmod = null,
		ssrc = null,
		sendrecv,
		mux,
		zrtp = null,
		ctxI = passthru,
		ctxR = passthru,
		other_ssrc = null,
		lastseen = null,
		process_chain_up = [],
		process_chain_down = [],
		encoder = false,
		decoders = [],
		% If set to true then we'll have another one INTERIM_UPDATE
		% interval to wait for initial data
		alive = false,
		tref
	}
).

start(Module, Params, Addon) ->
	PPid = self(),
	gen_server:start(?MODULE, [Module, Params ++ [{parent, PPid}], Addon], []).
start_link(Module, Params, Addon) ->
	PPid = self(),
	gen_server:start_link(?MODULE, [Module, Params ++ [{parent, PPid}], Addon], []).

init([Module, Params, Addon]) when is_atom(Module) ->
	% Deferred init
	self() ! {init, {Module, Params, Addon}},

	{ok, #state{}}.

handle_call(Request, From, State) ->
	{reply, ok, State}.

handle_cast(
	{#rtp{} = Pkt, _, _},
	#state{rtp = Fd, ip = Ip, rtpport = Port, tmod = TMod, process_chain_down = Chain} = State
) ->
	{NewPkt, NewState} = process_chain(Chain, Pkt, State),
	TMod:send(Fd, Ip, Port, NewPkt),
	{noreply, NewState};
handle_cast(
	{#rtcp{} = Pkt, _, _},
	#state{rtp = Fd, ip = Ip, rtpport = Port, tmod = TMod, process_chain_down = Chain, mux = true} = State
) ->
	% If muxing is enabled (either explicitly or with a 'auto' parameter
	% then send RTCP muxed within RTP stream
	{NewPkt, NewState} = process_chain(Chain, Pkt, State),
	TMod:send(Fd, Ip, Port, NewPkt),
	{noreply, NewState};
handle_cast(
	{#rtcp{} = Pkt, _, _},
	#state{rtcp = Fd, ip = Ip, rtcpport = Port, tmod = TMod, process_chain_down = Chain} = State
) ->
	{NewPkt, NewState} = process_chain(Chain, Pkt, State),
	TMod:send(Fd, Ip, Port, NewPkt),
	{noreply, NewState};
handle_cast(
	{#zrtp{} = Pkt, _, _},
	#state{rtcp = Fd, ip = Ip, rtpport = Port, tmod = TMod, process_chain_down = Chain} = State
) ->
	TMod:send(Fd, Ip, Port, zrtp:encode(Pkt)),
	{noreply, State};

handle_cast({raw, Ip, Port, {PayloadType, Msg}}, State) ->
	% FIXME
	{noreply, State};

handle_cast({update, Params}, State) ->
	% FIXME consider changing another params as well
	SendRecvStrategy = get_send_recv_strategy(Params),
	{ok, State#state{sendrecv = SendRecvStrategy}};

handle_cast(Request, State) ->
	{noreply, State}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

terminate(Reason, #state{rtp = Fd0, rtcp = Fd1, tmod = TMod, tref = TRef, encoder = Encoder, decoders = Decoders}) ->
	timer:cancel(TRef),
	TMod:close(Fd0),
	% FIXME We must send RTCP bye here
	TMod:close(Fd1),
	case Encoder of
		false -> ok;
		_ -> codec:close(Encoder)
	end,
	lists:foreach(fun(Codec) -> codec:close(Codec) end, Decoders).

handle_info(
	{udp, Fd, Ip, Port, <<?RTP_VERSION:2, _:7, PType:7, _:48, SSRC:32, _/binary>> = Msg},
	#state{parent = Parent, sendrecv = SendRecv, process_chain_up = Chain} = State
) when PType =< 34; 96 =< PType ->
	inet:setopts(Fd, [{active, once}]),
	case SendRecv(Ip, Port, SSRC, State#state.ip, State#state.rtpport, State#state.ssrc) of
		true ->
			{NewMsg, NewState} = process_chain(Chain, Msg, State),
			Parent ! {NewMsg, Ip, Port},
			{noreply, newState#state{lastseen = now(), alive = true, ip = Ip, rtpport = Port, ssrc = SSRC}};
		false ->
			{noreply, State}
	end;
handle_info(
	{udp, Fd, Ip, Port, <<?RTP_VERSION:2, _:7, PType:7, _:48, SSRC:32, _/binary>> = Msg},
	#state{parent = Parent, sendrecv = SendRecv, process_chain_up = Chain} = State
) when 64 =< PType, PType =< 82 ->
	inet:setopts(Fd, [{active, once}]),
	case SendRecv(Ip, Port, SSRC,  State#state.ip, State#state.rtcpport, State#state.ssrc) of
		true ->
			Mux = (State#state.mux == true) or ((State#state.rtpport == Port) and (State#state.mux == auto)),
			{NewMsg, NewState} = process_chain(Chain, Msg, State),
			Parent ! {NewMsg, Ip, Port},
			{noreply, NewState#state{lastseen = now(), alive = true, ip = Ip, rtcpport = Port, mux = Mux, ssrc = SSRC}};
		false ->
			{noreply, State}
	end;
handle_info(
	{udp, Fd, Ip, Port, <<?ZRTP_MARKER:16, _:16, ?ZRTP_MAGIC_COOKIE:32, SSRC:32, _/binary>> = Msg},
	#state{parent = Parent, sendrecv = SendRecv, process_chain_up = Chain} = State
) ->
	inet:setopts(Fd, [{active, once}]),
	% Treat ZRTP in the same way as RTP
	case SendRecv(Ip, Port, SSRC, State#state.ip, State#state.rtpport, State#state.ssrc) of
		true ->
			{ok, Zrtp} = zrtp:decode(Msg),
			case State#state.zrtp of
				% If we didn't setup ZRTP FSM then we are acting
				% as pass-thru ZRTP proxy
				null -> Parent ! Zrtp;
				ZrtpFsm -> gen_server:cast(self(), gen_server:call(ZrtpFsm, Zrtp))
			end,
			{noreply, State#state{lastseen = now(), alive = true, ip = Ip, rtpport = Port, ssrc = SSRC}};
		false ->
			{noreply, State}
	end;
handle_info(
	{udp, Fd, Ip, Port, <<?STUN_MARKER:2, _:30, ?STUN_MAGIC_COOKIE:32, _/binary>> = Msg},
	State
) ->
	inet:setopts(Fd, [{active, once}]),
	% FIXME this is a STUN message - we should reply at this level
	{noreply, State};

handle_info(interim_update, #state{parent = Parent, alive = true} = State) ->
	Parent ! interim_update,
	{noreply, State#state{alive=false}};
handle_info(interim_update, #state{alive = false} = State) ->
	{stop, timeout, State};

handle_info({init, {Module, Params, Addon}}, State) ->
	% Choose udp, tcp, sctp, dccp - FIXME only udp is supported
	Transport = proplists:get_value(transport, Params, udp),
	SockParams = proplists:get_value(sockparams, Params, []),
	% Either specify IPv4 or IPv6 explicitly or provide two special
	% values - "::" for any available IPv6 or "0.0.0.0" or "0" for
	% any available IPv4.
	{ok, IpAddr} = inet_parse:address(proplists:get_value(ip, Params, "0.0.0.0")),
	% Either specify port explicitly or provide none if don't care
	IpPort = proplists:get_value(port, Params, 0),
	% 'weak' - receives data from any Ip and Port with any SSRC
	% 'roaming' - receives data from only one Ip and Port *or* with the same SSRC as before
	% 'enforcing' - Ip, Port and SSRC *must* match previously recorded data
	SendRecvStrategy = get_send_recv_strategy(Params),
	% 'false' = no muxing at all (RTP will be sent in the RTP and RTCP - in the RTCP channels separately)
	% 'true' - both RTP and RTCP will be sent in the RTP channel
	% 'auto' - the same as 'false' until we'll find muxed packet.
	MuxRtpRtcp = proplists:get_value(rtcpmux, Params, auto),

	Timeout = proplists:get_value(timeout, Params, ?INTERIM_UPDATE),
	{ok, TRef} = timer:send_interval(Timeout, interim_update),

	{Fd0, Fd1} = get_fd_pair({Transport, IpAddr, IpPort, SockParams}),

	{ok, {Ip, PortRtp}} = inet:sockname(Fd0),
	{ok, {Ip, PortRtcp}} = inet:sockname(Fd1),

	% Either get explicit SRTP params or rely on ZRTP (which needs SSRC and ZID at least)
	{Zrtp, CtxI, CtxR, SSRC, OtherSSRC, SrtpEncode, SrtpDecode} = case proplists:get_value(ctx, Params, none) of
		none ->
			{null, null, null, null, null, [], []};
		zrtp ->
			{ok, ZrtpFsm} = zrtp:start_link([self()]),
			{ZrtpFsm, passthru, passthru, null, null, fun srtp_encode/2, fun srtp_decode/2};
		{{SI, CipherI, AuthI, AuthLenI, KeyI, SaltI}, {SR, CipherR, AuthR, AuthLenR, KeyR, SaltR}} ->
			CI = srtp:new_ctx(SI, CipherI, AuthI, KeyI, SaltI, AuthLenI),
			CR = srtp:new_ctx(SR, CipherR, AuthR, KeyR, SaltR, AuthLenR),
			{null, CI, CR, SI, SR, fun srtp_encode/2, fun srtp_decode/2}
	end,

	% FIXME
	{Encoder, Decoders, Transcode} = case proplists:get_value(transcode, Params, false) of
		false ->
			{
				false,
				[],
				[]
			};
		CodecDesc ->
			{
				codec:start_link(CodecDesc),
				lists:map(
					fun(CodecDesc) -> codec:start_link(CodecDesc) end,
					proplists:get_value(codecs, Params, [])
				),
				fun transcode/2
			}
	end,

	{noreply, #state{
			parent = proplists:get_value(parent, Params),
			rtp = Fd0,
			rtcp = Fd1,
			zrtp = Zrtp,
			ctxI = CtxI,
			ctxR = CtxR,
			ssrc = SSRC,
			other_ssrc = OtherSSRC,
			% FIXME - properly set transport
			tmod = gen_udp,
			process_chain_up = [fun rtp_decode/2]  ++ SrtpDecode ++ Transcode,
			process_chain_down = Transcode ++ SrtpEncode ++ [fun rtp_encode/2],
			encoder = Encoder,
			decoders = Decoders,
			mux = MuxRtpRtcp,
			sendrecv = SendRecvStrategy,
			tref = TRef
		}
	};

handle_info(Info, State) ->
	{noreply, State}.

%%
%% Private functions
%%

%% Open a pair of UDP ports - N and N+1 (for RTP and RTCP consequently)
get_fd_pair({Transport, {I0,I1,I2,I3,I4,I5,I6,I7} = IPv6, Port, SockParams}) when
	is_integer(I0), 0 =< I0, I0 < 65536,
	is_integer(I1), 0 =< I1, I1 < 65536,
	is_integer(I2), 0 =< I2, I2 < 65536,
	is_integer(I3), 0 =< I3, I3 < 65536,
	is_integer(I4), 0 =< I4, I4 < 65536,
	is_integer(I5), 0 =< I5, I5 < 65536,
	is_integer(I6), 0 =< I6, I6 < 65536,
	is_integer(I7), 0 =< I7, I7 < 65536 ->
	get_fd_pair(Transport, IPv6, Port, proplists:delete(ipv6, SockParams) ++ [inet6], 10);
get_fd_pair({Transport, {I0,I1,I2,I3} = IPv4, Port, SockParams}) when
	is_integer(I0), 0 =< I0, I0 < 256,
	is_integer(I1), 0 =< I1, I1 < 256,
	is_integer(I2), 0 =< I2, I2 < 256,
	is_integer(I3), 0 =< I3, I3 < 256 ->
	get_fd_pair(Transport, IPv4, Port, proplists:delete(ipv6, SockParams), 10).

get_fd_pair(Transport, I, P, SockParams, 0) ->
	error_logger:error_msg("Create new socket at ~s:~b FAILED (~p)", [inet_parse:ntoa(I), P,  SockParams]),
	error;
get_fd_pair(Transport, I, P, SockParams, NTry) ->
	case gen_udp:open(P, [binary, {ip, I}, {active, once}, {raw,1,11,<<1:32/native>>}] ++ SockParams) of
		{ok, Fd} ->
			{ok, {Ip,Port}} = inet:sockname(Fd),
			Port2 = case Port rem 2 of
				0 -> Port + 1;
				1 -> Port - 1
			end,
			case gen_udp:open(Port2, [binary, {ip, Ip}, {active, once}, {raw,1,11,<<1:32/native>>}] ++ SockParams) of
				{ok, Fd2} ->
					if
						Port > Port2 -> {Fd2, Fd};
						Port < Port2 -> {Fd, Fd2}
					end;
				{error, _} ->
					gen_udp:close(Fd),
					get_fd_pair(Transport, I, P, SockParams, NTry - 1)
			end;
		{error, _} ->
			get_fd_pair(Transport, I, P, SockParams, NTry - 1)
	end.

get_send_recv_strategy(Params) ->
	case proplists:get_value(sendrecv, Params, roaming) of
		weak -> fun send_recv_simple/6;
		roaming -> fun send_recv_roaming/6;
		enforcing -> fun send_recv_enforcing/6
	end.

%%
%% Various callbacks
%%

% 'weak' mode - just get data, decode and notify subscriber
send_recv_simple(_, _, _, _, _, _) -> true.

% 'roaming' mode - get data, check for the Ip and Port or for the SSRC (after decoding), decode and notify subscriber
% Legitimate RTP/RTCP packet - discard SSRC matching
send_recv_roaming(Ip, Port, _, Ip, Port, _) -> true;
% First RTP/RTCP packet
send_recv_roaming(Ip, Port, SSRC, _, null, _) -> true;
% Changed address - roaming
send_recv_roaming(Ip, Port, SSRC, _, _, SSRC) -> true;
% Different IP and SSRC - drop
send_recv_roaming(_, _, _, _, _, _) -> false.

% 'enforcing' - Ip, Port and SSRC must match previously recorded data
% Legitimate RTP/RTCP packet
send_recv_enforcing(Ip, Port, SSRC, Ip, Port, SSRC) -> true;
% First RTP/RTCP packet
send_recv_enforcing(Ip, Port, SSRC, _, null, _) -> true;
% Different IP and/or SSRC - drop
send_recv_enforcing(_, _, _, _, _, _) -> false.

process_chain([], Pkt, State) ->
	{Pkt, State};
process_chain([Fun|Funs], Pkt, State) ->
	{NewPkt, NewState} = Fun(Pkt, State),
	process_chain(Funs, NewPkt, NewState).

rtp_encode(Pkt, S) ->
	{rtp:encode(Pkt), S}.
rtp_decode(Pkt, S) ->
	{ok, NewPkt} = rtp:encode(Pkt),
	{NewPkt, S}.

srtp_encode(Pkt, State = #state{ctxR = Ctx}) ->
	{ok, NewPkt, NewCtx} = srtp:decrypt(Pkt, Ctx),
	{NewPkt, State#state{ctxR = NewCtx}}.
srtp_decode(Pkt, State = #state{ctxI = Ctx}) ->
	{ok, NewPkt, NewCtx} = srtp:decrypt(Pkt, Ctx),
	{NewPkt, State#state{ctxI = NewCtx}}.

transcode(Pkt, State = #state{encoder = false}) ->
	{Pkt, State};
transcode(#rtp{payload_type = OldPayloadType, payload = Payload} = Rtp, State = #state{encoder = {PayloadType, Encoder}, decoders = Decoders}) ->
	Decoder = proplists:get_value(OldPayloadType, Decoders),
	{ok, RawData} = codec:decode(Decoder, Payload),
	{ok, NewPayload} = codec:encode(Encoder, RawData),
	{Rtp#rtp{payload_type = PayloadType, payload = NewPayload}, State};
transcode(Pkt, State) ->
	{Pkt, State}.