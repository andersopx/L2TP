# L2TP

统一入口脚本：`l2tp-Rv14.sh`

## 用法
- 自动识别（默认）：`./l2tp-Rv14.sh` 或 `./l2tp-Rv14.sh --profile=auto`
  - 自动探测服务器公网 IP 所属国家：`CN` 则使用国内 DNS，其他情况使用国外 DNS。
  - 如网络受限导致探测失败，会回退到国外 DNS（`hk`）。
- 国内增强：`./l2tp-Rv14.sh --profile=cn`
- 国外增强：`./l2tp-Rv14.sh --profile=hk`
- 稳定兼容（17.30 风格）：`./l2tp-Rv14.sh --profile=17.30`
- 一键自检（不安装不改配置）：`./l2tp-Rv14.sh --self-check`

## 合并后的优化点
- 只维护一个脚本，避免多份副本长期漂移。
- DNS、DPD、PPP 保活、keepalive 策略统一通过 profile 切换。
- `cn/hk` 使用增强探测参数；`17.30` 保留稳定优先参数（含禁用 keepalive 定时器）。
- 实时状态页可显示：在线时长、下载/上传速率、总速率、累计流量（按当前会话接口统计）。
