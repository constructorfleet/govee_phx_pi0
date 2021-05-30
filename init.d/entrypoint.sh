#!/bin/bash +e
# Catch Signals As PID 1 in a Container

APP_COMMAND=${1:-"/opt/elixir/bin/mix phx.server"}

# Verify Container is Running in Host Mode
if [[ -z `grep "docker0" /proc/net/dev` ]]; then
  echo "Container not running in host mode. Sure you configured host network mode? Container stopped."
  exit 143
fi

# Verify Container is Running in Privileged Mode
ip link add dummy0 type dummy >/dev/null 2>&1
if [[ -z `grep "dummy0" /proc/net/dev` ]]; then
  echo "Container not running in privileged mode. Sure you configured privileged mode? Container stopped."
  exit 143
else
  # clean the dummy0 link
  ip link delete dummy0 >/dev/null 2>&1
fi

pid=0

# SIGNAL Handler
term_handler() {
 
 echo "stopping bluetooth daemon ..."
 if [ $pid -ne 0 ]; then
        kill -SIGTERM "$pid"
        wait "$pid"
 fi

  echo "bring hci0 down ..."
  hciconfig hci0 down
 
  echo "terminating dbus ..."
  /etc/init.d/dbus stop
  
  echo "terminating ssh ..."
  /etc/init.d/ssh stop

  exit 143; # 128 + 15 -- SIGTERM
}

# On Callback, Stop All Started Processes in term_handler
trap 'kill ${!}; term_handler' SIGINT SIGKILL SIGTERM SIGQUIT SIGTSTP SIGSTOP SIGHUP

echo "Starting SSH server on ${SSHPORT:-22} ..."
if [ "$SSHPORT" ]; then
  #there is an alternative SSH port configured
  sed -i -e "s;#Port 22;Port $SSHPORT;" /etc/ssh/sshd_config
fi

sudo /etc/init.d/ssh start

# Start Docker Deamon
echo "starting dbus ..."
/etc/init.d/dbus start

# Start Bluetooth Daemon
/usr/libexec/bluetooth/bluetoothd -d &
pid="$!"

# Reset BCM Chip Ensuring Access Outside Container Context
/opt/vc/bin/vcmailbox 0x38041 8 8 128 0  > /dev/null
sleep 1
/opt/vc/bin/vcmailbox 0x38041 8 8 128 1  > /dev/null 
sleep 1

# Load Firmware to BCM Chip and Attach to hci0
hciattach /dev/ttyAMA0 bcm43xx 115200 noflow

# Bring hci0 Up
hciconfig hci0 up


"/opt/elixir/bin/mix", "phx.server"
# Run Application
$APP_COMMAND

exit 0
