# HY2 for Alpine

Alpine Linux（amd64 / arm64）上以 root 执行，并放行 UDP 54321：

```sh
sh <(wget -qO- -T 30 https://raw.githubusercontent.com/zzwsec/hy2/main/hy2.sh)
```

安装完成后自动输出 HY2 分享链接，之后可用 `hy2 info` 查看。
