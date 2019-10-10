FROM ubuntu:16.04
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && \
    apt-get install -qy \
      curl ca-certificates gnupg2 dirmngr build-essential \
      gawk git autoconf automake pkg-config \
      bison libffi-dev libgdbm-dev libncurses5-dev libsqlite3-dev libtool \
      libyaml-dev sqlite3 zlib1g-dev libgmp-dev libreadline-dev libssl-dev \
      ruby --no-install-recommends && \
    apt-get clean

RUN gpg2 --recv-keys 409B6B1796C275462A1703113804BB82D39DC0E3 7D2BAF1CF37B13E2069D6956105BD0E739499BDB
RUN curl -sSL https://get.rvm.io | bash -s
ARG RVM_RUBY_VERSION=ruby-head
RUN /bin/bash -l -c "echo $RVM_RUBY_VERSION"
RUN /bin/bash -l -c ". /etc/profile.d/rvm.sh && rvm install $RVM_RUBY_VERSION --binary || rvm install $RVM_RUBY_VERSION"
ADD . /stackprof/
WORKDIR /stackprof/
RUN /bin/bash -l -c ". /etc/profile.d/rvm.sh && gem install bundler:1.16.0"
RUN /bin/bash -l -c ". /etc/profile.d/rvm.sh && bundle install"
RUN /bin/bash -l -c ". /etc/profile.d/rvm.sh && bundle exec rake build"
CMD /bin/bash -l -c ". /etc/profile.d/rvm.sh && bundle exec rake"
