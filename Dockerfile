#STEP 1 of multistage build ---Compile Bluetooth stack-----
FROM balenalib/raspberry-pi-debian:buster-20210506 as btbuilder

#environment variables
ENV BLUEZ_VERSION 5.54

RUN apt-get update && apt-get install -y \
    build-essential \
    wget \
    libical-dev \
    libdbus-1-dev \
    libglib2.0-dev \
    libreadline-dev \
    libudev-dev \
    systemd

RUN wget -P /tmp/ https://www.kernel.org/pub/linux/bluetooth/bluez-${BLUEZ_VERSION}.tar.gz \
    && tar xf /tmp/bluez-${BLUEZ_VERSION}.tar.gz -C /tmp \
#compile bluez
    && cd /tmp/bluez-${BLUEZ_VERSION} \
    && ./configure --prefix=/usr \
        --mandir=/usr/share/man \
        --sysconfdir=/etc \
        --localstatedir=/var \
        --enable-library \
        --enable-experimental \
        --enable-maintainer-mode \
        --enable-deprecated \
    && make \
    #install bluez tools
    && make install

#STEP 2 of multistage build ----Setup Elixir and Dependencies-----
FROM balenalib/araspberry-pi-debian:buster-20210506 as elixirbuilder

RUN sudo apt-get update && sudo apt-get install -y \
        libusb-1.0-0-dev \
        libssl-dev \
	    vim \
	    git \
        wget \
        unzip \
        gcc \
        make \
        inotify-tools \
        libncurses5 \
        libncurses5-dev \
        libwxbase3.0-0v5 \
        libwxbase3.0-dev \
        libwxgtk3.0-0v5 \
        libwxgtk3.0-dev \
        libsctp1 \
        nodejs \
        npm

WORKDIR /usr/lib/jvm
RUN sudo wget https://cdn.azul.com/zulu-embedded/bin/zulu11.48.21-ca-jdk11.0.11-linux_aarch32hf.tar.gz && \
	sudo tar -xzvf zulu11.48.21-ca-jdk11.0.11-linux_aarch32hf.tar.gz && \
	sudo rm -f zulu11.48.21-ca-jdk11.0.11-linux_aarch32hf.tar.gz && \
        sudo update-alternatives --install /usr/bin/java java /usr/lib/jvm/zulu11.48.21-ca-jdk11.0.11-linux_aarch32hf/bin/java 1 && \
        sudo update-alternatives --install /usr/bin/javac javac /usr/lib/jvm/zulu11.48.21-ca-jdk11.0.11-linux_aarch32hf/bin/javac 1 && \
        sudo update-alternatives --set java /usr/lib/jvm/zulu11.48.21-ca-jdk11.0.11-linux_aarch32hf/bin/java && \
        sudo update-alternatives --set javac /usr/lib/jvm/zulu11.48.21-ca-jdk11.0.11-linux_aarch32hf/bin/javac

WORKDIR /opt/erlang
RUN sudo wget https://packages.erlang-solutions.com/erlang/debian/pool/esl-erlang_21.3.8.10-1~raspbian~buster_armhf.deb && \
	sudo dpkg -i esl-erlang_21.3.8.10-1~raspbian~buster_armhf.deb

WORKDIR /opt/elixir
RUN sudo wget https://github.com/elixir-lang/elixir/releases/download/v1.10.0/Precompiled.zip && \
	sudo unzip Precompiled.zip -d . && \
    sudo rm -f Precompiled.zip && \
    ln -s /opt/elixir/bin/elixir /usr/bin/elixir && \
	ln -s /opt/elixir/bin/mix /usr/bin/mix

#STEP 3 of multistage build ----Build Application-----
FROM elixirbuilder as appbuilder

WORKDIR /srv/govee

RUN ln -s /opt/elixir/bin/elixir /usr/bin/elixir && \
	ln -s /opt/elixir/bin/mix /usr/bin/mix && \
        /opt/elixir/bin/mix local.hex --force && \
        /opt/elixir/bin/mix local.rebar --force

COPY . .

RUN export MIX_ENV=dev && \
	/opt/elixir/bin/mix deps.get --unlock && \
	/opt/elixir/bin/mix compile && \
        ls ./_build/dev/lib && \
        /bin/bash contrib/fix_perms.sh

FROM appbuilder

# Intall pre-reqs
RUN apt-get update && apt-get install -y \
        openssh-server \
        dbus \
        git \
        curl \
        libglib2.0-dev && \
# Setup SSH/Root
    echo 'root:root' | chpasswd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/' /etc/ssh/sshd_config && \
    sed 's@session\s*required\s*pam_loginuid.so@session optional pam_loginuid.so@g' -i /etc/pam.d/sshd && \
    mkdir /var/run/sshd && \
# Retrieve BCM Chip Firmware
    mkdir /etc/firmware && \
    curl -o /etc/firmware/BCM43430A1.hcd -L \
        https://github.com/OpenELEC/misc-firmware/raw/master/firmware/brcm/BCM43430A1.hcd && \
# Create folders for bluetooth tools
    mkdir -p '/usr/bin' \
        '/usr/libexec/bluetooth' \
        '/usr/lib/cups/backend' \
        '/etc/dbus-1/system.d' \
        '/usr/share/dbus-1/services' \
        '/usr/share/dbus-1/system-services' \
        '/usr/include/bluetooth' \
        '/usr/share/man/man1' \
        '/usr/share/man/man8' \
        '/usr/lib/pkgconfig' \
        '/usr/lib/bluetooth/plugins' \
        '/lib/udev/rules.d' \
        '/lib/systemd/system' \
        '/usr/lib/systemd/user' \
        '/lib/udev' && \
# Install Userland Raspberry Pi Tools
    git clone -b "1.20210527" --single-branch --depth 1 https://github.com/raspberrypi/firmware /tmp/firmware && \
    mv /tmp/firmware/hardfp/opt/vc /opt && \
    echo "/opt/vc/lib" >/etc/ld.so.conf.d/00-vmcs.conf && \
    /sbin/ldconfig \
# Cleanup
    && rm -rf /tmp/* \
    && rm -rf /opt/vc/src \
    && apt-get -yqq autoremove \
    && apt-get -y clean

# Copy Entrypoint Script
COPY "./init.d/*" /etc/init.d/

# Copy Bluez Tools From btbuilder Container
WORKDIR /usr/bin
COPY --from=bbtuilder /usr/bin/bluetoothctl \
                    /usr/bin/btmon \
                    /usr/bin/rctest \
                    /usr/bin/l2test \
                    /usr/bin/l2ping \
                    /usr/bin/bccmd \
                    /usr/bin/bluemoon \
                    /usr/bin/hex2hcd \
                    /usr/bin/mpris-proxy \
                    /usr/bin/btattach \
                    /usr/bin/hciattach \
                    /usr/bin/hciconfig \
                    /usr/bin/hcitool \
                    /usr/bin/hcidump \
                    /usr/bin/rfcomm \
                    /usr/bin/sdptool \
                    /usr/bin/ciptool \
                    ./
WORKDIR /usr/libexec/bluetooth
COPY --from=bbtuilder /usr/libexec/bluetooth/bluetoothd \
                    /usr/libexec/bluetooth/obexd \
                    ./
WORKDIR /usr/lib/cups/backend
COPY --from=bbtuilder /usr/lib/cups/backend/bluetooth \
                    ./
WORKDIR /etc/dbus-1/system.d
COPY --from=bbtuilder /etc/dbus-1/system.d/bluetooth.conf \
                    ./
WORKDIR /usr/share/dbus-1/services
COPY --from=bbtuilder /usr/share/dbus-1/services/org.bluez.obex.service \
                    ./
WORKDIR /usr/share/dbus-1/system-services
COPY --from=bbtuilder /usr/share/dbus-1/system-services/org.bluez.service \
                    ./
WORKDIR /usr/include/bluetooth
COPY --from=bbtuilder /usr/include/bluetooth/* \
                    ./
WORKDIR /usr/share/man/man1
COPY --from=bbtuilder /usr/share/man/man1/* \
                    ./
WORKDIR /usr/share/man/man8
COPY --from=bbtuilder /usr/share/man/man8/bluetoothd.8 \
                    ./
WORKDIR /usr/lib/pkgconfig
COPY --from=bbtuilder /usr/lib/pkgconfig/bluez.pc \
                    ./
WORKDIR /usr/lib/bluetooth/plugins
COPY --from=bbtuilder /usr/lib/bluetooth/plugins/external-dummy.so \
                    ./
WORKDIR /usr/lib/bluetooth/plugins
COPY --from=bbtuilder /usr/lib/bluetooth/plugins/external-dummy.la \
                    ./
WORKDIR /lib/udev/rules.d
COPY --from=bbtuilder /lib/udev/rules.d/97-hid2hci.rules \
                    ./
WORKDIR /lib/systemd/system
COPY --from=bbtuilder /lib/systemd/system/bluetooth.service \
                    ./
WORKDIR /usr/lib/systemd/user
COPY --from=bbtuilder /usr/lib/systemd/user/obex.service \
                    ./
WORKDIR /lib/udev
COPY --from=bbtuilder /lib/udev/hid2hci \
                    ./

#SSH port
EXPOSE 22

#do startscript
ENTRYPOINT ["/etc/init.d/entrypoint.sh", "/opt/elixir/bin/mix phx.server"]

#set STOPSGINAL
STOPSIGNAL SIGTERM
