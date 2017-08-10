#!/bin/sh


###############################################################################
# Node manager shell script version.                                          #
###############################################################################

###############################################################################
# helper functions                                                            #
###############################################################################

###############################################################################
# Reads a line from the specified file and returns it in REPLY.               #
# Error message supressed if file not found.                                  #
###############################################################################
read_file() {
  if [ -f "$1" ]; then
    read REPLY 2>$NullDevice <"$1"
  else
    return 1
  fi
}

###############################################################################
# Writes a line to the specified file. The line will first be written         #
# to a temporary file which is then used to atomically overwrite the          #
# destination file. This prevents a simultaneous read from getting            #
# partial data.                                                               #
###############################################################################
write_file() {
  file="$1"; shift
  echo $* >>"$file.tmp"
  mv -f -- "$file.tmp" "$file"
}

###############################################################################
# Updates the state file with new server state information.                   #
###############################################################################
write_state() {
  write_file "$StateFile" "$1"
}

###############################################################################
# Prints informational message to server output log.                          #
###############################################################################
print_info() {
  echo "<`date`> <Info> <NodeManager> <"$@">"
}

###############################################################################
# Prints error message to server output log.                                  #
###############################################################################
print_err() {
  echo "<`date`> <Error> <NodeManager> <"$@">"
}

###############################################################################
# reads java pid to $svrv_pid variable
###############################################################################
read_java_pid() {
  # Check for pid file
  read_file "$PidFile"

  if [ "x$?" = "x0" ]; then
    srvr_pid=$REPLY
  fi

  # Make sure server is started
  if ! monitor_is_running; then
    return 1
  fi

  if ! java_is_running; then
    return 1
  fi

  return 0
}

###############################################################################
# Force kill tomcat pid                                                       #
###############################################################################
force_kill() {
  read_java_pid
  if [ "x$?" = "x0" -a "x$srvr_pid" != "x" ]; then
    kill -9 $srvr_pid
    return $?
  else
    echo "Jboss is not currently running" >&2
    return 1
  fi
}

###############################################################################
# Makes thread dump of the running java process.                              #
###############################################################################
make_thread_dump() {
  read_java_pid
  if [ "x$?" = "x0" -a "x$srvr_pid" != "x" ]; then
    kill -3 $srvr_pid
    return $?
  else
    echo "Jboss is not currently running" >&2
    return 1
  fi
}

###############################################################################
# Makes thread dump of the running java process and executes less             #
###############################################################################
list_thread_dump() {
  make_thread_dump
  if [ "x$?" = "x0" ]; then
    sleep 1
    less +"?Full thread dump Java HotSpot" -- "$OutFile"
  else
    echo "Jboss is not currently running" >&2
    return 1
  fi
}

###############################################################################
# Returns true if the process with the specified pid is still alive.          #
###############################################################################
is_alive() {
  if [ -d /proc ]; then
    [ -r "/proc/$1" -a "x" != "x$1" ]
  else
    ps -p $1 2>$NullDevice | grep -q $1
  fi
}

###############################################################################
# Returns true if the server state file indicates                             #
# that the server has started.                                                #
###############################################################################
server_is_started() {
  if read_file "$StateFile"; then
    case $REPLY in
      *:Y:*) return 0 ;;
    esac
  fi
  return 1
}

###############################################################################
# Returns true if the server state file indicates                             #
# that the server has not yet started.                                        #
###############################################################################
server_not_yet_started() {
  if server_is_started; then
    return 1;
  else
    return 0;
  fi
}

###############################################################################
# Returns true if the monitor is running otherwise false. Also will remove    #
# the monitor lock file if it is no longer valid.                             #
###############################################################################
monitor_is_running() {
  if read_file "$LockFile" && is_alive $REPLY; then
    /sbin/fuser "$LockFile" > $NullDevice 2>&1
    if [ "x$?" = "x0" ]; then
      return 0
    fi
  fi
  rm -f -- "$LockFile"
  return 1
}

###############################################################################
# Returns true if the java is running otherwise false. Also will remove       #
# the pid file if it is no longer valid.                                      #
###############################################################################
java_is_running() {
  if read_file "$PidFile" && is_alive $REPLY; then
    /sbin/fuser "$PidFile" > $NullDevice 2>&1
    if [ "x$?" = "x0" ]; then
      return 0
    fi
  fi
  rm -f -- "$PidFile"
  return 1
}

###############################################################################
# Get the current time as an equivalent time_t.  Note that this may not be    #
# always right, but should be good enough for our purposes of monitoring      #
# intervals.                                                                  #
###############################################################################
time_as_timet() {
    if [ "x$BaseYear" = "x0" ]; then
        BaseYear=1970
    fi
    cur_timet=`date -u +"%Y %j %H %M %S" | awk '{
        base_year = 1970
        year=$1; day=$2; hour=$3; min=$4; sec=$5;
        yearsecs=int((year  - base_year)* 365.25 ) * 86400
        daysecs=day * 86400
        hrsecs=hour*3600
        minsecs=min*60
        total=yearsecs + daysecs + hrsecs + minsecs + sec
        printf "%08d", total
        }'`
}

###############################################################################
# Update the base start time if it is 0.  Every time a server stops,          #
# if the time since last base time is > restart interval, it is reset         #
# to 0.  Next restart of the server will set the last base start time         #
# to the new time                                                             #
###############################################################################
update_base_time() {
  time_as_timet
  if [ "x$LastBaseStartTime" = "x0" ]; then
    LastBaseStartTime=$cur_timet
  fi
}

###############################################################################
# Computes the seconds elapsed between last start time and current time       #
###############################################################################
compute_diff_time() {
    #get current time as time_t
    time_as_timet
    diff_time=`expr $cur_timet - $LastBaseStartTime`
}

###############################################################################
# Kills process tree                                                          #
###############################################################################
killtree() {
  local pid=$1
  local sig=${2-TERM}
  print_info "Stopping pid $pid"
  kill -stop $pid
  if [ "x$?" = "x0" ]; then
    for child in `ps -o pid --no-headers --ppid $pid`; do
      killtree $child $sig
    done
    print_info "Sending $sig signal to $pid"
    kill -$sig $pid
    kill -CONT $pid
  fi
}

###############################################################################
# Rotate the specified log file. Rotated log files are named                  #
# <server-name>.outXXXXX where XXXXX is the current log count and the         #
# highest is the most recent. The log count starts at 00001 then cycles       #
# again if it reaches 99999.                                                  #
###############################################################################
save_log() {
  fileLen=`echo "${OutFile}" | wc -c`
  fileLen=`expr ${fileLen} + 1`
  lastLog=`ls -r1 -- "$OutFile"????? "$OutFile" 2>$NullDevice | head -1`
  logCount=`ls -r1 -- "$OutFile"????? "$OutFile" 2>$NullDevice | head -1 | cut -c $fileLen-`
  if [ "x$logCount" = "x" ]; then
    logCount=0
  fi
  if [ "x$logCount" = "x99999" ]; then
    logCount=0
  fi
  logCount=`expr ${logCount} + 1`
  zeroPads=""
  case $logCount in
    [0-9]) zeroPads="0000" ;;
    [0-9][0-9]) zeroPads="000" ;;
    [0-9][0-9][0-9]) zeroPads="00" ;;
    [0-9][0-9][0-9][0-9]) zeroPads="0" ;;
  esac
  rotatedLog="$OutFile"$zeroPads$logCount
  mv -f -- "$OutFile" "$rotatedLog"
  /sbin/fuser -k -HUP "$rotatedLog" >$NullDevice 2>&1
}

###############################################################################
# Rotate the specified log file in size based manner                          #
###############################################################################
start_log_rotate() {
  while true; do
    trap "" 1
    sleep 60
    if [ -f "$OutFile" ]; then
      size=`stat -c '%s' -- "$OutFile"`
      if [ $size -ge $LogRotateSize ]; then
        save_log
      fi
    fi
  done
}

###############################################################################
# Detect deadlocks
###############################################################################
start_deadlock_detection() {
  while true; do
    sleep $DeadlockDetectionInterval
    check_deadlock
    if [ "x$?" = "x0" ]; then
      print_info "Found deadlock"
      make_thread_dump
      force_kill
    fi
  done
}

###############################################################################
# Checks whether java process has a deadlock                                  #
###############################################################################
check_deadlock() {
  if [ ! -x "$JAVA_HOME/bin/jstack" ]; then
    return 1
  fi

  read_java_pid
  if [ "x$?" = "x0" -a "x$srvr_pid" != "x" ]; then
    jstack $srvr_pid | grep 'Found .* Java-level deadlock' > $NullDevice 2>&1
    return $?
  fi

  return 1
}

###############################################################################
# Make sure server directory exists and is valid.                             #
###############################################################################
check_dirs() {
  if [ ! -d "$CATALINA_HOME" ]; then
    echo "Directory '$CATALINA_HOME' not found.  Make sure \$CATALINA_HOME directory exists and is accessible" >&2
    exit 1
  fi

  if [ ! -d "$CATALINA_BASE" ]; then
    echo "Directory '$CATALINA_BASE' not found.  Make sure \$CATALINA_BASE directory exists and is accessible" >&2
    exit 1
  fi

  mkdir -p -- "$CATALINA_BASE/log"
  mkdir -p -- "$CATALINA_BASE/nodemanager"
}

###############################################################################
# Process node manager START command. Starts server with current startup      #
# properties and enters the monitor loop which will automatically restart     #
# the server when it fails.                                                   #
###############################################################################
do_start() {
  # Make sure server is not already started
  if monitor_is_running; then
    echo "Tomcat has already been started" >&2
    return 1
  fi
  # If monitor is not running, but if we can determine that the Tomcat
  # process is running, then say that server is already running.
  if java_is_running; then
    echo "Tomcat has already been started" >&2
    return 1
  fi
  # Save previous server output log
  if [ -f "$OutFile" ]; then
    save_log
  fi
  # Remove previous state file
  rm -f -- "$StateFile"
  # Change to server root directory
  cd -- "$CATALINA_BASE"
  # Now start the server and monitor loop
  start_and_monitor_server &
  # Wait for server to start up
  while is_alive $! && server_not_yet_started; do
    sleep 1
  done
  if server_not_yet_started; then
    echo "Tomcat failed to start (see server output log for details)" >&2
    return 1
  fi
  return 0
}

start_and_monitor_server() {

  # Create server lock file
  pid=`exec sh -c 'ps -o ppid -p $$|sed '1d''`
  write_file "$LockFile" $pid
  exec 3>>"$LockFile"

  trap "rm -f -- \"$LockFile\"" 0
  trap "exec >>\"$OutFile\" 2>&1" 1
  # Disconnect input and redirect stdout/stderr to server output log
  exec 0<$NullDevice
  exec >>"$OutFile" 2>&1
  # Start server and monitor loop
  count=0

  setup_tomcat_cmdline

  while true; do
    count=`expr ${count} + 1`
    update_base_time

    if [ "x$LogRotateSize" != "x0" ]; then
      start_log_rotate &
      print_info "Starting log rotating, pid $!"
    fi

    if [ "x$DeadlockDetectionInterval" != "x0" ]; then
      start_deadlock_detection &
      print_info "Starting deadlock detection, pid $!"
    fi

    start_server_script

    for job_pid in `jobs -p`; do
      print_info "Killing pid $job_pid"
      killtree $job_pid
    done

    read_file "$StateFile"
    case $REPLY in
      *:N:*)
        print_err "Server startup failed (will not be restarted)"
        write_state FAILED_NOT_RESTARTABLE:N:Y
        return 1
      ;;
      SHUTTING_DOWN:*:N | FORCE_SHUTTING_DOWN:*:N)
        print_info "Server was shut down normally"
        write_state SHUTDOWN:Y:N
        return 0
      ;;
    esac
    compute_diff_time
    if [ $diff_time -gt $RestartInterval ]; then
      #Reset count
      count=0
      LastBaseStartTime=0
    fi
    if [ "x$AutoRestart" != "xtrue" ]; then
      print_err "Server failed but is not restartable because autorestart is disabled."
      write_state FAILED_NOT_RESTARTABLE:Y:N
      return 1
    elif [ $count -gt $RestartMax ]; then
      print_err "Server failed but is not restartable because the maximum number of restart attempts has been exceeded"
      write_state FAILED_NOT_RESTARTABLE:Y:N
      return 1
    fi
    print_info "Server failed so attempting to restart"
      # Optionally sleep for RestartDelaySeconds seconds before restarting
    if [ $RestartDelaySeconds -gt 0 ]; then
      write_state FAILED:Y:Y
      sleep $RestartDelaySeconds
    fi
  done
}

###############################################################################
# Starts the Tomcat server                                                     #
###############################################################################
start_server_script() {
  print_info "Starting Tomcat with command line: $CommandName $CommandArgs"
  write_state STARTING:N:N
  (

     pid=`exec sh -c 'ps -o ppid -p $$|sed '1d''`

     write_file "$PidFile" $pid
     exec 3>>"$PidFile"

     exec $CommandName $CommandArgs 2>&1) | (
     trap "exec >>\"$OutFile\" 2>&1" 1
     IFS=""; while read line; do
       case $line in
         *\Server\ startup\ in*)
           write_state RUNNING:Y:N
         ;;
         *\Stopping\ service\ Catalina*)
           write_state SHUTTING_DOWN:Y:N
         ;;
       esac
       echo $line;
    done
  )

  print_info "Tomcat exited"
  return 0
}

setup_tomcat_cmdline() {

  MEM_ARGS="-Xms128m -Xmx512m -XX:MaxPermSize=256m"
  if [ "x$USER_MEM_ARGS" != "x" ]; then
    MEM_ARGS="$USER_MEM_ARGS"
  fi

  # Setup the classpath
  runjar="$CATALINA_HOME/bin/bootstrap.jar"
  if [ ! -f "$runjar" ]; then
    echo "Missing required file: $runjar" >&2
    return 1
  fi

  TOMCAT_BOOT_CLASSPATH="$runjar"

  # Tomcat uses the JDT Compiler
  # Only include tools.jar if someone wants to use the JDK instead.
  # compatible distribution which JAVA_HOME points to
  if [ "x$JAVAC_JAR" = "x" ]; then
    JAVAC_JAR_FILE="$JAVA_HOME/lib/tools.jar"
  else
    JAVAC_JAR_FILE="$JAVAC_JAR"
  fi

  if [ ! -f "$JAVAC_JAR_FILE" -a "x$JAVAC_JAR" != "x"  ]; then
    warn "Missing file: JAVAC_JAR=$JAVAC_JAR"
    warn "Unexpected results may occur."
    JAVAC_JAR_FILE=
  fi

  # Ensure that any user defined CLASSPATH variables are not used on startup,
  # but allow them to be specified in setenv.sh, in rare case when it is needed.
  CLASSPATH=
  if [ -r "$CATALINA_BASE/bin/setenv.sh" ]; then
    . "$CATALINA_BASE/bin/setenv.sh"
  elif [ -r "$CATALINA_HOME/bin/setenv.sh" ]; then
    . "$CATALINA_HOME/bin/setenv.sh"
  fi

  if [ -r "$CATALINA_HOME/bin/setclasspath.sh" ]; then
    . "$CATALINA_HOME/bin/setclasspath.sh"
  else
    echo "Cannot find $CATALINA_HOME/bin/setclasspath.sh"
    echo "This file is needed to run this program"
    exit 1
  fi

  # Setup the JVM
  if [ "x$JAVA_HOME" != "x" -a -x "$JAVA_HOME/bin/java" ]; then
    JAVA="$JAVA_HOME/bin/java"
  else
    echo "Please specify a valid JAVA_HOME" >&2
    return 1
  fi

  if [ "x$CLASSPATH" = "x" ]; then
    CLASSPATH="$TOMCAT_BOOT_CLASSPATH"
  else
    CLASSPATH="$CLASSPATH:$TOMCAT_BOOT_CLASSPATH"
  fi

  if [ "x$JAVAC_JAR_FILE" != "x" ]; then
    CLASSPATH="$CLASSPATH:$JAVAC_JAR_FILE"
  fi

  if [ -r "$CATALINA_BASE/bin/tomcat-juli.jar" ]; then
    CLASSPATH=$CLASSPATH:$CATALINA_BASE/bin/tomcat-juli.jar
  else
    CLASSPATH=$CLASSPATH:$CATALINA_HOME/bin/tomcat-juli.jar
  fi

  if [ "x$POST_CLASSPATH" != "x" ]; then
    CLASSPATH="$CLASSPATH:$POST_CLASSPATH"
  fi

  if [ "x$PRE_CLASSPATH" != "x" ]; then
    CLASSPATH="$PRE_CLASSPATH:$CLASSPATH"
  fi

  # Set juli LogManager config file if it is present and an override has not been issued
  echo $JAVA_OPTS | grep Djava.util.logging.config.file= > $NullDevice 2>&1
  if [ "x$?" != "x0" ]; then
    if [ "x$LOGGING_CONFIG" = "x" ]; then
      if [ -r "$CATALINA_BASE/conf/logging.properties" ]; then
        LOGGING_CONFIG="-Djava.util.logging.config.file=$CATALINA_BASE/conf/logging.properties"
      else
        LOGGING_CONFIG="-Dnop"
      fi
    fi
    JAVA_OPTS="$JAVA_OPTS $LOGGING_CONFIG"
  fi


  echo $JAVA_OPTS | grep Djava.util.logging.manager= > $NullDevice 2>&1
  if [ "x$?" != "x0" ]; then
    if [ "x$LOGGING_MANAGER" = "x" ]; then
      LOGGING_MANAGER="-Djava.util.logging.manager=org.apache.juli.ClassLoaderLogManager"
    fi
    JAVA_OPTS="$JAVA_OPTS $LOGGING_MANAGER"
  fi

  echo $JAVA_OPTS | grep Djava.endorsed.dirs= > $NullDevice 2>&1
  if [ "x$?" != "x0" ]; then
    if [ "x$JAVA_ENDORSED_DIRS" != "x" ]; then
      JAVA_OPTS="$JAVA_OPTS -Djava.endorsed.dirs=$JAVA_ENDORSED_DIRS"
    fi
  fi
  
  echo $JAVA_OPTS | grep Djava.io.tmpdir= > $NullDevice 2>&1
  if [ "x$?" != "x0" ]; then
    if [ "x$CATALINA_TMPDIR" = "x" ] ; then
      CATALINA_TMPDIR="$CATALINA_BASE/temp"
    fi
    mkdir -p -- "$CATALINA_TMPDIR"
    JAVA_OPTS="$JAVA_OPTS -Djava.io.tmpdir=$CATALINA_TMPDIR"
  fi

  # If -server not set in JAVA_OPTS, set it, if supported
  echo $JAVA_OPTS | grep "\-client" > $NullDevice 2>&1
  if [ "x$?" != "x0" ]; then
    echo $JAVA_OPTS | grep "\-server" > $NullDevice 2>&1
    if [ "x$?" != "x0" ]; then
      $JAVA -version | grep -i HotSpot > $NullDevice 2>&1
      if [ "x$?" != "x0" ]; then
        JAVA_OPTS="-server $JAVA_OPTS"
      fi
    fi
  fi

  #Setup Tomcat specific properties
  JAVA_OPTS="$JAVA_OPTS -Dcatalina.home=$CATALINA_HOME -Dcatalina.base=$CATALINA_BASE -classpath $CLASSPATH"

  CommandName=$JAVA
  CommandArgs="$JAVA_OPTS $MEM_ARGS org.apache.catalina.startup.Bootstrap start"


echo $CommandName
echo $CommandArgs
}

###############################################################################
# Process node manager KILL command to kill the currently running server.     #
# Returns true if successful otherwise returns false if the server process    #
# was not running or could not be killed.                                     #
###############################################################################
do_kill() {
  read_java_pid
  if [ "x$?" != "x0" -o "x$srvr_pid" = "x" ]; then
    echo "Tomcat is not currently running" >&2
    return 1
  fi

  # Kill the server process
  write_state SHUTTING_DOWN:Y:N
  kill $srvr_pid

  # Now wait for up to $StopTimeout seconds for monitor to die
  count=0
  while [ $count -lt $StopTimeout ] && monitor_is_running; do
    sleep 1
    count=`expr ${count} + 1`
  done
  if monitor_is_running; then
    write_state FORCE_SHUTTING_DOWN:Y:N
    echo "Server process did not terminate in $StopTimeout seconds after being signaled to terminate, killing" 2>&1
    kill -9 $srvr_pid
  fi
}

do_stat() {
  valid_state=0

  if read_file "$StateFile"; then
    statestr=$REPLY
    state=`echo $REPLY| sed 's/_ON_ABORTED_STARTUP//g'`
    state=`echo $state | sed 's/:.//g'`
  else
    statestr=UNKNOWN:N:N
    state=UNKNOWN
  fi

  if monitor_is_running; then
    valid_state=1
  elif java_is_running; then
    valid_state=1
  fi

  cleanup=N

  if [ "x$valid_state" = "x0" ]; then
    case $statestr in
      SHUTTING_DOWN:*:N | FORCE_SHUTTING_DOWN:*:N)
        state=SHUTDOWN
        write_state $state:Y:N
      ;;
      *UNKNOWN*) ;;
      *SHUT*) ;;
      *FAIL*) ;;
      *:Y:*)
        state=FAILED_NOT_RESTARTABLE
        cleanup=Y
      ;;
      *:N:*)
        state=FAILED_NOT_RESTARTABLE
        cleanup=Y
      ;;
    esac

    if [ "x$cleanup" = "xY" ]; then
      if server_is_started; then
        write_state $state:Y:N
      else
        write_state $state:N:N
      fi
    fi
  fi

  if  [ "x$InternalStatCall" = "xY" ]; then
    ServerState=$state
  else
    echo $state
  fi
}

###############################################################################
# run command.                                                                #
###############################################################################
do_command() {
    case $NMCMD in
    START)  check_dirs
            do_start
    ;;
    STARTP) check_dirs
            do_start
    ;;
    STAT)   do_stat ;;
    KILL)   do_kill ;;
    STOP)   do_kill ;;
    GETLOG) cat "$OutFile" 2>$NullDevice ;;
    TAILLOG) while true; do tail -100f "$OutFile" 2>$NullDevice; done ;;
    THREADDUMP) list_thread_dump ;;
    *)      echo "Unrecognized command: $1" >&2 ;;
    esac
}


###############################################################################
# Prints command usage message.                                               #
###############################################################################
print_usage() {
  cat <<__EOF__
Usage: $0 [OPTIONS] CMD
Where options include:
    -h                          Show this help message
    -D<name>[=<value>]          Set a system property
    -c <name>                   Set the CATALINA_BASE directory, optional
    -r <dir>                    Set the CATALINA_HOME directory, required
__EOF__
}


PROGNAME=$0

AutoRestart=true
RestartMax=2
RestartDelaySeconds=0
LastBaseStartTime=0
NullDevice=/dev/null

###############################################################################
# Prerequirements
###############################################################################

if [ ! -x /sbin/fuser ]; then
  echo "/sbin/fuser executable does not exist"
  exit 1
fi

if [ "x$BASH" = "x" ]; then
  echo "current shell is not a bash"
  exit 1
fi

###############################################################################
# Parse command line options                                                  #
###############################################################################
eval "set -- $@"
while getopts hD:c:r: flag "$@"; do
  case $flag in
    h)
     print_usage
     exit 0
    ;;
    r)
     CATALINA_HOME=$OPTARG
    ;;
    c)
     CATALINA_BASE=$OPTARG
    ;;
    D)
     JAVA_OPTS="$JAVA_OPTS -D$OPTARG"
    ;;
    *) echo "Unrecognized option: $flag" >&2
     exit 1
    ;;
  esac
done

if [ ${OPTIND} -gt 1 ]; then
  shift `expr ${OPTIND} - 1`
fi

if [ $# -lt 1 ]; then
  echo "Please specify a command to execute"
  print_usage
  exit 1
fi

if [ "x$CATALINA_HOME" = "x" ]; then
  echo "Please specify CATALINA_HOME directory"
  print_usage
  exit 1
fi

if [ "x$CATALINA_BASE" = "x" ]; then
  CATALINA_BASE=$CATALINA_HOME
fi



NMCMD=`echo $1 | tr '[a-z]' '[A-Z]'`

OutFile=$CATALINA_BASE/log/catalina.out
PidFile=$CATALINA_BASE/nodemanager/catalina.pid
LockFile=$CATALINA_BASE/nodemanager/catalina.lck
StateFile=$CATALINA_BASE/nodemanager/catalina.state

if [ "x$RestartInterval" = "x" ]; then
  RestartInterval=10
fi

if [ "x$LogRotateSize" = "x" ]; then
  LogRotateSize=1073741824
fi

if [ "x$DeadlockDetectionInterval" = "x" ]; then
  DeadlockDetectionInterval=300
fi

if [ "x$StopTimeout" = "x" ]; then
  StopTimeout=60
fi

do_command

