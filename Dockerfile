FROM redis:6.2.4-buster AS redis

FROM python:3.8 as pybuild

COPY cpython.patch /tmp/cpython.patch
RUN git clone https://github.com/python/cpython.git
RUN cd cpython \
&& git checkout v3.8.0 \
&& git apply --verbose --ignore-space-change --ignore-whitespace /tmp/cpython.patch
RUN cd cpython \
&& ./configure --enable-optimizations --prefix=/usr \
&& make -j 4 sharedmods

FROM python:3.8-slim

RUN groupadd -r -g 999 redis && useradd -r -g redis -u 999 redis
COPY --from=redis /usr/local/bin/redis-server /usr/local/bin/redis-server
COPY --from=redis /usr/local/bin/redis-benchmark /usr/local/bin/redis-benchmark
COPY --from=redis /usr/local/bin/redis-check-aof /usr/local/bin/redis-check-aof
COPY --from=redis /usr/local/bin/redis-check-rdb /usr/local/bin/redis-check-rdb
COPY --from=redis /usr/local/bin/redis-cli /usr/local/bin/redis-cli
RUN mkdir /data && chown redis:redis /data
VOLUME /data

RUN echo "UTC" >  /etc/timezone
ENV TZ "UTC"

RUN apt-get update -y \
    && apt-get install -y --no-install-recommends unzip p7zip tzdata libmagic1 wget locales \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# setup locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG en_US.UTF-8
ENV LANGUAGE en_US:en
ENV LC_ALL en_US.UTF-8

COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -U pip ipython==7.25.0 && pip install --no-cache-dir -r /tmp/requirements.txt
COPY setup.py LICENSE MANIFEST.in README.md requirements.txt /app/
COPY src app/src
RUN cd /app && python setup.py install && cd - && rm -rf /app

# redis-restart script is use to start redis initally (redis-restart 0)
# but also to restart it later-on using --defrag-redis param.
# in this case, the param is the redis PID.
# environment variable REDIS_PID provides it.
RUN printf "#!/bin/sh\n\
pid=\$1\n\
if [ -z \"\$pid\" ];\n\
then\n\
    echo \"Missing REDIS PID.\"\n\
    exit 1\n\
fi\n\
\n\
if [ ! \"\$pid\" = \"0\" ];\n\
then\n\
    echo \"Killing REDIS at \$pid\"\n\
    kill \$pid\n\
    sleep 3\n\
fi\n\
echo -n \"Starting redis\"\n\
redis-server --daemonize yes --save \"\" --appendonly no \
--unixsocket /var/run/redis.sock --unixsocketperm 744 \
--dir /output \
--port 6379 --bind 0.0.0.0 --pidfile /var/run/redis.pid\n\
\n\
while ! test -f /var/run/redis.pid; do\n\
  sleep 1\n\
  echo -n "."\n\
done\n\
REDIS_PID=\$(/bin/cat /var/run/redis.pid)\n\
echo \". PID: \${REDIS_PID}\"\n" > /usr/local/bin/redis-restart && \
chmod a+x /usr/local/bin/redis-restart

# entrypoint starts redis then executes CMD
RUN printf "#!/bin/sh\n\
redis-restart 0\n\n\
export REDIS_PID=\$(/bin/cat /var/run/redis.pid)\n\
exec \"\$@\"\n" > /usr/local/bin/start-redis-daemon && \
chmod +x /usr/local/bin/start-redis-daemon

RUN mkdir -p /output

COPY --from=pybuild /cpython/build/lib.linux-x86_64-3.8/unicodedata.cpython-38-x86_64-linux-gnu.so /usr/local/lib/python3.8/lib-dynload/unicodedata.cpython-38-x86_64-linux-gnu.so
COPY --from=pybuild /cpython/build/lib.linux-x86_64-3.8/pyexpat.cpython-38-x86_64-linux-gnu.so /usr/local/lib/python3.8/lib-dynload/pyexpat.cpython-38-x86_64-linux-gnu.so

EXPOSE 6379
ENTRYPOINT ["start-redis-daemon"]

CMD ["sotoki", "--help"]
