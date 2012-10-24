%% @doc Coordinates full sync replication parallelism.

-module(riak_repl2_fscoordinator).
-behaviour(gen_server).
-define(SERVER, ?MODULE).

-record(state, {
    leader_node :: 'undefined' | node(),
    leader_pid :: 'undefined' | node(),
    other_cluster,
    socket,
    transport,
    largest_n,
    owners = [],
    connection_ref,
    partition_queue = queue:new(),
    whereis_waiting = []
}).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/1]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%% ------------------------------------------------------------------
%% connection manager Function Exports
%% ------------------------------------------------------------------

-export([connected/5,connect_failed/3]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Cluster) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Cluster, []).

%% ------------------------------------------------------------------
%% connection manager callbacks
%% ------------------------------------------------------------------

connected(Socket, Transport, Endpoint, Proto, Pid) ->
    Transport:controlling_process(Socket, Pid),
    gen_server:cast(Pid, {connected, Socket, Transport, Endpoint, Proto}).

connect_failed(_ClientProto, Reason, SourcePid) ->
    gen_server:cast(SourcePid, {connect_failed, self(), Reason}).

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

init(Cluster) ->
    process_flag(trap_exit, true),
    TcpOptions = [
        {kepalive, true},
        {nodelay, true},
        {packet, 4},
        {active, false}
    ],
    ClientSpec = {{fs_coordinate, [{1,0}]}, {TcpOptions, ?MODULE, self()}},
    case riak_core_connection_mgr:connect({rt_repl, Cluster}, ClientSpec) of
        {ok, Ref} ->
            {ok, #state{other_cluster = Cluster, connection_ref = Ref}};
        {error, Error} ->
            lager:warning("Error connection to remote"),
            {stop, Error}
    end.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({connected, Socket, Transport, _Endpoint, _Proto}, State) ->
    Ring = riak_core_ring_manager:get_my_ring(),
    N = largest_n(Ring),
    Partitions = sort_partitions(Ring),
    FirstN = length(Partitions) div N,
    
    State2 = State#state{
        socket = Socket,
        transport = Transport,
        largest_n = N,
        owners = riak_core_ring:all_owners(Ring),
        partition_queue = queue:from_list(Partitions)
    },
    State3 = send_whereis_reqs(State2, FirstN),
    {noreply, State3};

    % TODO kick off the replication
    % for each P in partition, 
    %   ask local pnode if therea new worker can be started.
    %   if yes
    %       reach out to remote side asking for ip:port of matching pnode
    %       on reply, start worker on local pnode
    %   else
    %       put partition in 'delayed' list
    %   
    % of pnode in that dise
    % for each P in partitions, , reach out to the physical node
    % it lives on, tell it to connect to remote, and start syncing
    % link to the fssources, so they when this does,
    % and so this can handle exits fo them.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, Cause}, State) when Cause =:= normal; Cause =:= shutdown ->
    Partition = erlang:erase(Pid),
    case Partition of
        undefined ->
            {noreply, State};
        _ ->
            % are we done?
            PDict =  erlang:get() == [],
            QEmpty = queue:is_empty(State#state.partition_queue),
            Waiting = State#state.whereis_waiting,
            case {PDict, QEmpty, Waiting} of
                {[], true, []} ->
                    % nothing outstanding, so we can exit.
                    {stop, normal, State};
                _ ->
                    % there's something waiting for a response.
                    State2 = send_next_whereis_req(State),
                    {noreply, State2}
            end
    end;

handle_info({'EXIT', Pid, _Cause}, State) ->
    lager:warning("fssource ~p exited abnormally", [Pid]),
    Partition = erlang:erase(Pid),
    case Partition of
        undefined ->
            {noreply, State};
        _ ->
            % TODO putting in the back of the queue a good idea?
            #state{partition_queue = PQueue} = State,
            PQueue2 = queue:in(Partition, PQueue),
            State2 = State#state{partition_queue = PQueue2},
            State3 = send_next_whereis_req(State2),
            {noreply, State3}
    end;

handle_info({_Proto, Socket, Data}, #state{socket = Socket} = State) ->
    #state{transport = Transport} = State,
    Transport:setopts(Socket, [{active, once}]),
    Data1 = binary_to_term(Data),
    State2 = handle_socket_msg(Data1, State),
    {noreply, State2};

%handle_info({'EXIT', Pid, Cause}, State) ->
    % TODO: handle when a partition fs exploderizes
%    Partition = erlang:erase(Pid),
%    case {Cause, Partition} of
%        {_, undefined} ->
%            {noreply, State};
%        {normal, _} ->
%            start_fssource
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

handle_socket_msg({location, Partition, {_Node, Ip, Port}}, #state{whereis_waiting = Waiting} = State) ->
    case proplists:get_value(Partition, Waiting) of
        undefined ->
            State;
        N ->
            Waiting2 = proplists:delete(Partition, Waiting),
            State2 = State#state{whereis_waiting = Waiting2},
            Partition2 = {Partition, N},
            State3 = start_fssource(Partition2, Ip, Port, State2),
            send_next_whereis_req(State3)
    end.

send_whereis_reqs(State, 0) ->
    State;
send_whereis_reqs(State, N) ->
    State2 = send_next_whereis_req(State),
    send_whereis_reqs(State2, N - 1).

send_next_whereis_req(State) ->
    #state{transport = Transport, socket = Socket, partition_queue = PQueue, whereis_waiting = Waiting} = State,
    case queue:out(PQueue) of
        {empty, Q} ->
            State#state{partition_queue = Q};
        {{value, P}, Q} ->
            case node_available(P, State) of
                false ->
                    State;
                true ->
                    Waiting2 = [P | Waiting],
                    {PeerIP, PeerPort} = inet:peername(Socket),
                    riak_repl_tcp_server:send(Transport, Socket, {whereis, element(1, P), PeerIP, PeerPort}),
                    State#state{partition_queue = Q, whereis_waiting = Waiting2}
            end
    end.

node_available({Partition,_}, State) ->
    #state{owners = Owners} = State,
    LocalNode = proplists:get_value(Partition, Owners),
    Max = app_helper:get_env(riak_repl, max_fssource, 5),
    RunningList = riak_repl2_fssource_sup:enabled(LocalNode),
    length(RunningList) < Max.

start_fssource({Partition,_}, Ip, Port, State) ->
    #state{owners = Owners} = State,
    LocalNode = proplists:get_value(Partition, Owners),
    {ok, Pid} = riak_repl2_fssource_sup:enable(LocalNode, Partition, {Ip, Port}),
    link(Pid),
    erlang:put(Pid, Partition),
    State.

largest_n(Ring) ->
    Defaults = app_helper:get_env(riak_core, default_bucket_props, []),
    Buckets = riak_core_bucket:get_buckets(Ring),
    lists:foldl(fun(Bucket, Acc) ->
                max(riak_core_bucket:n_val(Bucket), Acc)
        end, riak_core_bucket:n_val(Defaults), Buckets).

sort_partitions(Ring) ->
    BigN = largest_n(Ring),
    RawPartitions = [P || {P, _Node} <- riak_core_ring:all_owners(Ring)],
    %% tag partitions with their index, for convienience in detecting preflist
    %% collisions later
    Partitions = lists:zip(RawPartitions,lists:seq(1,length(RawPartitions))),
    %% pick a random partition in the ring
    R = crypto:rand_uniform(0, length(Partitions)),
    %% pretend that the ring starts at offset R
    {A, B} = lists:split(R, Partitions),
    OffsetPartitions = B ++ A,
    %% now grab every Nth partition out of the ring until there are no more
    sort_partitions(OffsetPartitions, BigN, []).

sort_partitions([], _, Acc) ->
    lists:reverse(Acc);
sort_partitions(In, N, Acc) ->
    Split = min(length(In), N) - 1,
    {A, [P|B]} = lists:split(Split, In),
    sort_partitions(B++A, N, [P|Acc]).
