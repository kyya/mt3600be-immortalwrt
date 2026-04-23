# 构建依赖

`build.sh --deps-only` 会自动在 Ubuntu/Debian 装好。其他发行版参考下面。

## Ubuntu 22.04 / 24.04 (自动)

脚本会装这些：

```
build-essential clang flex bison g++ gawk
gcc-multilib g++-multilib gettext git libncurses-dev libssl-dev
python3 python3-pip python3-ply python3-docutils python3-pyelftools
rsync swig unzip zlib1g-dev file wget subversion ccache tmux curl
ca-certificates pkg-config libelf-dev zstd qemu-utils quilt
```

## Fedora / CentOS / RHEL

```bash
sudo dnf install -y @development-tools \
  bison byacc bzip2 diffutils flex git glibc-static \
  gmp-devel libmpc-devel make mpfr-devel ncurses-devel \
  openssl-devel patch perl python3 python3-devel \
  rsync subversion swig tar unzip wget which zlib-devel \
  quilt ccache
```

## Arch Linux

```bash
sudo pacman -S --needed base-devel \
  git subversion asciidoc bash bind bzip2 fastjar flex \
  gawk gettext gperf help2man intltool libusb libxslt \
  make ncurses openssl perl-extutils-makemaker \
  python rsync sdcc unzip util-linux wget zlib \
  quilt ccache
```

## Docker（如果你想在容器里编）

```bash
# 拉 ImmortalWrt 官方提供的 builder 镜像（如果有）
# 或者从 ubuntu:22.04 自己起：
docker run -it --rm -v $PWD:/work -w /work ubuntu:22.04 bash
# 进容器后：
apt-get update && ./build.sh
```

## macOS

**不推荐。** ImmortalWrt 官方明确说 macOS builds 无保证。如果你真要试：

```bash
brew install coreutils findutils gnu-getopt gnu-sed gnu-tar wget ccache
# 然后挂 case-sensitive volume（APFS 默认大小写不敏感，会炸）
```

## 磁盘空间建议

- ImmortalWrt 源码 + feeds：~3 GB
- build 输出：~15 GB
- ccache：推荐 20 GB（`ccache -M 20G`）
- **总计**：给 ≥50 GB 比较稳

## 内存建议

- 最低 4GB
- 推荐 8GB 以上
- 16GB 编起来会流畅不少（尤其 `make -j$(nproc)` 时）
- 16GB 以下建议开 4-8GB swap，链接阶段会吃内存
