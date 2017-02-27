-module (mondemand_backend_stats_rrd_builder).

-behaviour (gen_server).

-include ("mondemand_backend_stats_rrd_internal.hrl").

%% API
-export ([ start_link/0,
           calculate_context/3,
           build/1
         ]).

%% gen_server callbacks
-export ([ init/1,
           handle_call/3,
           handle_cast/2,
           handle_info/2,
           terminate/2,
           code_change/3
         ]).

-record (state, {}).
-define (NAME, mdbes_rrd_builder).

%%====================================================================
%% API
%%====================================================================
start_link () ->
  gen_server:start_link ({local, ?NAME}, ?MODULE, [], []).

calculate_context (Prefix, FileKey, Dirs) ->
  % normalize to binary to simplify rest of code
  ProgId = mondemand_util:binaryify (
             mondemand_backend_stats_rrd_key:prog_id (FileKey)
           ),
  MetricName = mondemand_util:binaryify (
                 mondemand_backend_stats_rrd_key:metric_name (FileKey)
               ),
  MetricType = mondemand_backend_stats_rrd_key:metric_type (FileKey),
  Host = mondemand_util:binaryify (
           mondemand_backend_stats_rrd_key:host (FileKey)
         ),
  Context = [ {mondemand_util:binaryify (K), mondemand_util:binaryify (V) }
              || {K, V}
              <- mondemand_backend_stats_rrd_key:context (FileKey)
            ],

  % all aggregated values end up with a <<"stat">> context value, so
  % remove it and get the type
  AggregatedType =
    case lists:keyfind (<<"stat">>,1,Context) of
      false -> undefined;
      {_,AT} -> AT
    end,

  % this should have no impact on systems which use absolute paths
  % but for those which use relative paths this will make sure
  % symlinks (and maybe soon hardlinks), work.  Mostly this is
  % for development
  FullyQualifiedPrefix =
    case Prefix of
      [$/ | _ ] -> Prefix;
      _ ->
        {ok, CWD} = file:get_cwd(),
        filename:join ([CWD, Prefix])
    end,

  % generate some paths and files which graphite understands
  {LegacyFileDir, LegacyFileName} =
     legacy_rrd_path (FullyQualifiedPrefix, ProgId, MetricType,
                      MetricName, Host, Context),

  {GraphiteFileDir, GraphiteFileName} =
     graphite_rrd_path (FullyQualifiedPrefix, ProgId, MetricType,
                        MetricName, Host, Context,
                        AggregatedType =/= undefined,
                        Dirs),

  #mdbes_rrd_builder_context {
    file_key = FileKey,
    metric_type = MetricType,
    aggregated_type = AggregatedType,
    legacy_rrd_file_dir = LegacyFileDir,
    legacy_rrd_file_name = LegacyFileName,
    graphite_rrd_file_dir = GraphiteFileDir,
    graphite_rrd_file_name = GraphiteFileName
  }.

build (BuilderContext) ->
  gen_server:cast (?NAME, {build, BuilderContext}).

%%====================================================================
%% gen_server callbacks
%%====================================================================
init ([]) ->
  { ok, #state {} }.

handle_call (Request, From, State = #state {}) ->
  error_logger:warning_msg ("~p : Unrecognized call ~p from ~p~n",
                            [?MODULE, Request, From]),
  { reply, ok, State }.

handle_cast ({ build,
               Context = #mdbes_rrd_builder_context { file_key = FileKey }
             },
             State = #state {}) ->
  case maybe_create_files (Context) of
    {ok, _} ->
      mondemand_backend_stats_rrd_filecache:mark_created (FileKey);
    E ->
      mondemand_backend_stats_rrd_filecache:mark_error (FileKey, E)
  end,
  {noreply, State};
handle_cast (Request, State = #state {}) ->
  error_logger:warning_msg ("~p : Unrecognized cast ~p~n",[?MODULE, Request]),
  { noreply, State }.

handle_info (Request, State = #state { }) ->
  error_logger:warning_msg ("~p : Unrecognized info ~p~n",[?MODULE, Request]),
  { noreply, State }.

terminate (_Reason, #state {}) ->
  ok.

code_change (_OldVsn, State, _Extra) ->
  { ok, State }.

%%====================================================================
%% internal functions
%%====================================================================
legacy_rrd_path (Prefix, ProgId,
                   {statset, SubType}, MetricName, Host, Context) ->
  legacy_rrd_path (Prefix, ProgId, SubType, MetricName, Host, Context);
legacy_rrd_path (Prefix, ProgId, MetricType, MetricName, Host, Context) ->
  ContextString =
    case Context of
      [] -> "";
      L -> [ "-",
             mondemand_server_util:join ([[K,"=",V] || {K, V} <- L ], "-")
           ]
    end,

  FileName = list_to_binary ([ProgId,
                              "-",atom_to_list (MetricType),
                              "-",MetricName,
                              "-",Host,
                              ContextString,
                              ".rrd"]),
  FilePath =
    filename:join([Prefix,
                   ProgId,
                   MetricName]),

  {FilePath, FileName}.

graphite_normalize_host (Host) ->
  case re:run(Host,"([^\.]+)", [{capture, all_but_first, binary}]) of
    {match, [H]} -> H;
    nomatch -> Host
  end.

graphite_normalize_token (Token) ->
  re:replace (Token, "\\W", "_", [global, {return, binary}]).


graphite_rrd_path (Prefix, ProgId,
                   {statset, SubType}, MetricName, Host, Context,
                   IsAggregate, Dirs) ->
  graphite_rrd_path (Prefix, ProgId, SubType, MetricName, Host, Context,
                     IsAggregate, Dirs);
graphite_rrd_path (Prefix, ProgId,  MetricType, MetricName, Host, Context,
                   IsAggregate, Dirs) ->
  ContextParts =
    case Context of
      [] -> [];
      L ->
        lists:flatten (
          [ [graphite_normalize_token (K), graphite_normalize_token (V)]
               || {K, V} <- L,
                  K =/= <<"stat">> ]
        )
    end,
  {HostDir, AggregateDir} = Dirs,
  % mondemand raw data will go in the "md" directory, aggregates will
  % go in the "agg" directory
  InnerPath =
    case IsAggregate of
      false -> HostDir;
      true -> AggregateDir
    end,
  FilePath =
    filename:join(
      [ Prefix++"g",  % append a 'g' to prefix since this is graphite
        graphite_normalize_token (ProgId),
        InnerPath,
        graphite_normalize_token (MetricName)
      ]
      ++ ContextParts
      ++ [ "host", graphite_normalize_host (Host) ]),
  FileName = list_to_binary ([atom_to_list (MetricType),".rrd"]),
  {FilePath, FileName}.

maybe_create_files ( #mdbes_rrd_builder_context {
                       metric_type = MetricType,
                       aggregated_type = AggregatedType,
                       legacy_rrd_file_dir = LegacyFileDir,
                       legacy_rrd_file_name = LegacyFileName,
                       graphite_rrd_file_dir = GraphiteFileDir,
                       graphite_rrd_file_name = GraphiteFileName
                     } ) ->
  RRDFile = filename:join ([LegacyFileDir, LegacyFileName]),

  case mondemand_server_util:mkdir_p (LegacyFileDir) of
    ok ->
      case maybe_create (MetricType, AggregatedType, RRDFile) of
        {ok, _} ->
          case mondemand_server_util:mkdir_p (GraphiteFileDir) of
            ok ->
              GRRDFile = filename:join ([GraphiteFileDir, GraphiteFileName]),

              % making symlinks for the moment
              file:make_symlink (RRDFile, GRRDFile),
              {ok, RRDFile};
            E ->
              {error, {cant_create_dir, GraphiteFileDir, E}}
          end;
        {timeout, Timeout} ->
          error_logger:error_msg (
            "Unable to create '~p' because of timeout ~p",[RRDFile, Timeout]),
          {error, timeout};
        {error, Error} ->
          error_logger:error_msg (
            "Unable to create '~p' because of ~p",[RRDFile, Error]),
          {error, Error};
        Unknown ->
          error_logger:error_msg (
            "Unable to create '~p' because of unknown ~p",[RRDFile, Unknown]),
          {error, Unknown}
      end;
    E2 ->
      {error, {cant_create_dir, LegacyFileDir, E2}}
  end.

maybe_create (Types, AggregatedType, File) ->
  {Type, SubType} =
     case Types of
       {T, S} -> {T, S};
       T -> {T, undefined}
     end,

  case file:read_file_info (File) of
    {ok, I} -> {ok, I};
    _ ->
      case Type of
        counter -> create_counter (File);
        gauge -> create_gauge (File);
        statset -> create_summary (SubType, AggregatedType, File);
        _ -> create_counter (File) % default is counter
      end
  end.

create_counter (File) ->
  % creates an RRD file of 438120 bytes
  erlrrd:create ([
      io_lib:fwrite ("~s",[File]),
      " --step \"60\""
      " --start \"now - 90 days\""
      " \"DS:value:DERIVE:900:0:U\""
      " \"RRA:AVERAGE:0.5:1:44640\""  % 31 days of 1 minute samples
      " \"RRA:AVERAGE:0.5:15:9600\""  % 100 days of 15 minute intervals
      " \"RRA:AVERAGE:0.5:1440:400\"" % 400 day of 1 day intervals
    ]).

create_gauge (File) ->
  % creates an RRD file of 438128 bytes
  erlrrd:create ([
      io_lib:fwrite ("~s",[File]),
      " --step \"60\""
      " --start \"now - 90 days\""
      " \"DS:value:GAUGE:900:U:U\""
      " \"RRA:AVERAGE:0.5:1:44640\""  % 31 days of 1 minute samples
      " \"RRA:AVERAGE:0.5:15:9600\""  % 100 days of 15 minute intervals
      " \"RRA:AVERAGE:0.5:1440:400\"" % 400 days of 1 day intervals
    ]).

create_summary (SubType, AggregatedType, File) ->
  RRDType =
    case AggregatedType of
      % statset's being used direct from client
      % will not have an aggregated type and are
      % reset each minute so are gauges
      undefined -> "GAUGE";
      % counter's will mostly be counters (in the RRD case we use DERIVE),
      % except for the count subtype which will be a gauge as it is always
      % for the last time period
      <<"counter">> ->
        case SubType of
          count -> "GAUGE";
          _ -> "DERIVE"
        end;
      <<"gauge">> -> "GAUGE";
      _ -> "GAUGE"
    end,
  erlrrd:create ([
      io_lib:fwrite ("~s",[File]),
      " --step \"60\""
      " --start \"now - 90 days\"",
      io_lib:fwrite (" \"DS:value:~s:900:U:U\"",[RRDType]),
      " \"RRA:AVERAGE:0.5:1:44640\""   % 31 days of 1 minute samples
      " \"RRA:AVERAGE:0.5:15:9600\""   % 100 days of 15 minute intervals
      " \"RRA:AVERAGE:0.5:1440:1200\"" % 1200 days of 1 day intervals
  ]).

%%--------------------------------------------------------------------
%%% Test functions
%%--------------------------------------------------------------------
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").


-endif.
