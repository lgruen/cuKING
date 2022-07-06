FROM nvidia/cuda:11.7.0-devel-ubuntu22.04 AS dev

ENV DEBIAN_FRONTEND=noninteractive

# Remove nvidia repositories to work around https://github.com/NVIDIA/nvidia-docker/issues/1402
RUN rm /etc/apt/sources.list.d/cuda-ubuntu2204-x86_64.list && \
    apt update && apt install --no-install-recommends -y \
        apt-transport-https \
        ca-certificates \
        cmake \
        curl \
        g++

# Google Cloud SDK
RUN echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee -a /etc/apt/sources.list.d/google-cloud-sdk.list && \
    curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key --keyring /usr/share/keyrings/cloud.google.gpg add - && \
    apt update && apt install -y google-cloud-sdk

RUN mkdir -p /deps/abseil-cpp && cd /deps/abseil-cpp && \
    curl -sSL https://github.com/abseil/abseil-cpp/archive/refs/tags/20220623.0.tar.gz | tar -xzf - --strip-components=1 && \
    cmake \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CXX_STANDARD=17 \
      -DBUILD_TESTING=OFF \
      -DBUILD_SHARED_LIBS=yes \
      -S . -B cmake-out && \
    cmake --build cmake-out --target install -- -j 16 && \
    ldconfig

RUN mkdir -p /deps/json && cd /deps/json && \
    curl -sSL https://github.com/nlohmann/json/archive/v3.10.5.tar.gz | tar -xzf - --strip-components=1 && \
    cmake \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_STANDARD=17 \
        -DBUILD_SHARED_LIBS=yes \
        -DBUILD_TESTING=OFF \
        -DJSON_BuildTests=OFF \
        -S . -B cmake-out && \
    cmake --build cmake-out --target install -- -j 16 && \
    ldconfig

RUN mkdir -p /deps/arrow && cd /deps/arrow && \
    curl -sSL https://github.com/apache/arrow/archive/refs/tags/apache-arrow-8.0.0.tar.gz | tar -xzf - --strip-components=1 && \
    mkdir build && cd build && \
    cmake ../cpp \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_CXX_STANDARD=17 \
    -DARROW_BUILD_STATIC=OFF \
    -DARROW_PARQUET=ON && \
    cmake --build . --target install -- -j 16 && \
    ldconfig

# extract-elf-so tars .so files to create small Docker images.
RUN curl -sSL -o /deps/extract-elf-so https://github.com/William-Yeh/extract-elf-so/releases/download/v0.6/extract-elf-so_static_linux-amd64 && \
    chmod +x /deps/extract-elf-so

FROM dev as extract

COPY . /app/
WORKDIR /app

RUN rm -rf build && \
    mkdir build && \
    cd build && \
    cmake -DCMAKE_BUILD_TYPE=Release .. && \
    cmake --build . -j 16

RUN /deps/extract-elf-so --cert /app/build/cuking

FROM nvidia/cuda:11.7.0-base-ubuntu22.04 AS minimal

RUN --mount=type=bind,from=extract,source=/app/rootfs.tar,target=/rootfs.tar \
    tar xf /rootfs.tar && \
    ldconfig
