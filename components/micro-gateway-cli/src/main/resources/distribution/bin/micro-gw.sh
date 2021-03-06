#!/bin/bash
# ---------------------------------------------------------------------------
#  Copyright (c) 2018, WSO2 Inc. (http://www.wso2.org) All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

# ----------------------------------------------------------------------------
# Startup Script for API Manager Micro Gateway for ${label} APIs
#
# NOTE: Borrowed generously from Apache Tomcat startup scripts.
# -----------------------------------------------------------------------------

# OS specific support.  $var _must_ be set to either true or false.
#ulimit -n 100000

# resolve links - $0 may be a softlink
PRG="$0"

while [ -h "$PRG" ]; do
  ls=`ls -ld "$PRG"`
  link=`expr "$ls" : '.*-> \(.*\)$'`
  if expr "$link" : '.*/.*' > /dev/null; then
    PRG="$link"
  else
    PRG=`dirname "$PRG"`/"$link"
  fi
done

# Get standard environment variables
PRGDIR=`dirname "$PRG"`

# set BALLERINA_HOME
GWHOME=`cd "$PRGDIR/.." ; pwd`
export BALLERINA_HOME=$GWHOME'/runtime'

if [ -e "$GWHOME/bin/gateway.pid" ]; then
  PID=`cat "$GWHOME"/bin/gateway.pid`
fi

# ----- Process the input command ----------------------------------------------
args=""
for c in $*
do
    if [ "$c" = "--debug" ] || [ "$c" = "-debug" ] || [ "$c" = "debug" ]; then
          CMD="--debug"
          continue
    elif [ "$CMD" = "--debug" ]; then
          if [ -z "$PORT" ]; then
                PORT=$c
          fi
    elif [ "$c" = "--stop" ] || [ "$c" = "-stop" ] || [ "$c" = "stop" ]; then
          CMD="stop"
    elif [ "$c" = "--start" ] || [ "$c" = "-start" ] || [ "$c" = "start" ]; then
          CMD="start"
    elif [ "$c" = "--version" ] || [ "$c" = "-version" ] || [ "$c" = "version" ]; then
          CMD="version"
    elif [ "$c" = "--restart" ] || [ "$c" = "-restart" ] || [ "$c" = "restart" ]; then
          CMD="restart"
    elif [ "$c" = "--test" ] || [ "$c" = "-test" ] || [ "$c" = "test" ]; then
          CMD="test"
    else
        args="$args $c"
    fi
done

if [ "$CMD" = "start" ]; then
  if [ -e "$GWHOME/bin/gateway.pid" ] && [ -z "$PID" ]; then
    if  ps -p $PID > /dev/null ; then
      echo "Process is already running"
      exit 0
    fi
  fi
  export GWHOME="$GWHOME"
  rm -f file $GWHOME/bin/gateway.pid
  # using nohup sh to avoid erros in solaris OS.TODO
  nohup sh $BALLERINA_HOME/bin/ballerina run $GWHOME/exec/${label}.balx -e b7a.http.accesslog.path=$GWHOME/logs/access_logs --config $GWHOME/conf/micro-gw.conf $args &
  SESS_PID=$!
  #getting the process id of the child process which spawn by the parent process
  PROCESS_ID=""
  while [ -z "$PROCESS_ID" ]
  do
  	PROCESS_ID=$(ps -ef | grep -P "^[^ ]+\s+[^ ]+\s+$SESS_PID\s" | awk '{print $2}')
  	sleep 0.1
  done
  echo $PROCESS_ID >> $GWHOME/bin/gateway.pid
  exit 0
elif [ "$CMD" = "stop" ]; then
  export GWHOME="$GWHOME"
  kill -term `cat "$GWHOME"/bin/gateway.pid`
  rm -f file $GWHOME/bin/gateway.pid
  exit 0
elif [ "$CMD" = "restart" ]; then
  export GWHOME="$GWHOME"
  kill -term `cat "$GWHOME"/bin/gateway.pid`
  process_status=0
  pid=`cat "$GWHOME"/bin/gateway.pid`
  while [ "$process_status" -eq "0" ]
  do
        sleep 1
        ps -p$pid 2>&1 > /dev/null
        process_status=$?
  done
  rm -f file $GWHOME/bin/gateway.pid
  # using nohup sh to avoid erros in solaris OS.TODO
  nohup sh $BALLERINA_HOME/bin/ballerina run $GWHOME/exec/${label}.balx -e b7a.http.accesslog.path=$GWHOME/logs/access_logs --config $GWHOME/conf/micro-gw.conf $args &
  SESS_PID=$!
  PROCESS_ID=""
  while [ -z "$PROCESS_ID" ]
  do
  	PROCESS_ID=$(ps -ef | grep -P "^[^ ]+\s+[^ ]+\s+$SESS_PID\s" | awk '{print $2}')
  	sleep 0.1
  done
  echo $PROCESS_ID >> $GWHOME/bin/gateway.pid
  exit 0
fi

# run the balx created for ${label} APIs
sh $BALLERINA_HOME/bin/ballerina run $GWHOME/exec/${label}.balx -e b7a.http.accesslog.path=$GWHOME/logs/access_logs --config $GWHOME/conf/micro-gw.conf