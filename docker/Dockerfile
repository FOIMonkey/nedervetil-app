ARG RUBY_VERSION=3.4.13
FROM ruby:${RUBY_VERSION}-trixie

ENV DOCKER=1
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y && \
    apt-get install -y postgresql-common && \
    /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y

RUN apt-get update -y && \
    apt-get install -y \
    bubblewrap \
    chromium \
    elinks \
    ghostscript \
    imagemagick \
    libemail-address-perl \
    libemail-outlook-message-perl \
    libmagic-dev \
    libreoffice-calc-nogui \
    libreoffice-impress-nogui \
    libreoffice-writer-nogui \
    pdftk-java \
    poppler-utils \
    postgresql-client-18 \
    qpdf \
    sendmail \
    tesseract-ocr \
    tesseract-ocr-eng \
    tesseract-ocr-osd \
    tnef \
    mutt

# Wait-for-it
RUN git clone https://github.com/vishnubob/wait-for-it.git /tmp/wait-for-it && \
    chmod +x /tmp/wait-for-it/wait-for-it.sh && \
    ln -s /tmp/wait-for-it/wait-for-it.sh /bin/wait-for-it

WORKDIR /alaveteli
RUN git config --global --add safe.directory /alaveteli

RUN gem update --system

EXPOSE 3000
CMD wait-for-it db:5432 --strict -- ./docker/entrypoint.sh
