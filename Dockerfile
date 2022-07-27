FROM alpine:3.15 as prepare
ENV PYTHONPATH /usr/local/lib/python3.9/site-packages
WORKDIR /app/
RUN set -x \
    && apk add --no-cache python3 \
    && :

FROM prepare as build

RUN set -x \
    && apk add --no-cache python3 \
    && apk add --no-cache --virtual .build-deps py3-pip build-base gcc musl-dev git \
       python3-dev linux-headers make \
    && pip3 install --prefix /usr/local uwsgi flask\
    && rm -rf /root/.cache \
    && apk del .build-deps \
    && :

COPY ./src/ /app/

FROM build as test

RUN set -x \
    && python3 test_main.py \
    && rm test_main.py \
    && :

FROM prepare 

ENV PYTHONUNBUFFERED 1
ENV UWSGI_HTTP :8000
ENV UWSGI_WSGI main:app
ENV UWSGI_WSGI main:app
ENV UWSGI_PROCESSES 4
ENV UWSGI_ENABLE_THREADS 1

WORKDIR /app/

COPY --from=test /usr/local/ /usr/local/
COPY --from=test /app/ /app/

USER 1001
EXPOSE 8000

CMD ["/usr/local/bin/uwsgi"]

