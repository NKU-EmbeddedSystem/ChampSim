# 使用指南

## 1. 构建

```bash
# 在此处补充构建命令
```

## 2. 运行

```bash
# 在此处补充运行命令
```

## 3. 测试

```bash
# 在此处补充测试命令
```

## 4. 查看文档

### 启动文档服务

```bash
cd <project-dir>
python3 -m http.server 8080 -d docs/html/
```

### SSH 隧道（远程服务器）

在本地机器执行：

```bash
ssh -L 8080:127.0.0.1:8080 -N user@<服务器地址>
```

浏览器打开 `http://localhost:8080` 即可。
