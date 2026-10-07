# shared/

预留：未来其他 Mastodon 运维工具（weibo-import 之外）的公共 Ruby 库。

当前为空。若后续出现跨工具复用的纯逻辑（时间解析、SSRF 防护、报告渲染等），
先在 `tools/<tool>/install/script/` 内沉淀，稳定后再提升到此处；
提升时必须保持 stdlib-only 红线，并通过各工具的 minitest。
