//
//  WebDevelopmentScaffold.swift
//  AiguruContainerPanel
//
//  为内置 Web 开发模板准备宿主机 bind mount。只补齐缺失资源，绝不覆盖已有项目文件。
//

import Foundation

enum WebDevelopmentScaffold {
    static func generate(in projectDirectory: String) throws -> [String] {
        let root = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        var created: [String] = []

        for relativePath in [
            "apps/frontend/dist", "apps/frontend/src", "apps/api/src", "apps/worker/src", "apps/node22", "apps/node24", "apps/php", "apps/spring-auth", "apps/spring-order", "apps/spring-gateway", "infra/nginx", "infra/dns", "infra/ssh", "infra/mariadb", "backups/mariadb", "shared/img"
        ] {
            let url = root.appendingPathComponent(relativePath, isDirectory: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                created.append(relativePath + "/")
            }
        }

        try writeIfMissing("""
        {
          "scripts": { "dev": "vite" },
          "devDependencies": { "typescript": "^5.0.0", "vite": "^6.0.0" }
        }
        """, to: root, relativePath: "apps/frontend/package.json", created: &created)
        try writeIfMissing("""
        <div id="app">Aiguru Web Development Stack</div><script type="module" src="/src/main.ts"></script>
        """, to: root, relativePath: "apps/frontend/index.html", created: &created)
        try writeIfMissing("""
        document.querySelector<HTMLDivElement>("#app")!.innerHTML = "<h1>TypeScript + Vite 已启动</h1>";
        """, to: root, relativePath: "apps/frontend/src/main.ts", created: &created)
        try writeIfMissing("""
        {
          "scripts": { "dev": "tsx watch src/server.ts", "worker": "tsx src/worker.ts" },
          "dependencies": { "tsx": "^4.0.0", "typescript": "^5.0.0" }
        }
        """, to: root, relativePath: "apps/api/package.json", created: &created)
        try writeIfMissing("""
        import { createServer } from "node:http";
        const port = Number(process.env.PORT ?? 3000);
        createServer((_request, response) => {
          response.writeHead(200, { "content-type": "application/json" });
          response.end(JSON.stringify({ ok: true, service: "api" }));
        }).listen(port, () => console.log(`API listening on ${port}`));
        """, to: root, relativePath: "apps/api/src/server.ts", created: &created)
        try writeIfMissing("""
        console.log("Worker started; connect your queue consumer here.");
        setInterval(() => undefined, 60_000);
        """, to: root, relativePath: "apps/api/src/worker.ts", created: &created)
        try writeIfMissing("""
        {
          "scripts": { "worker": "tsx src/worker.ts" },
          "dependencies": { "tsx": "^4.0.0", "typescript": "^5.0.0" }
        }
        """, to: root, relativePath: "apps/worker/package.json", created: &created)
        try writeIfMissing("""
        console.log("Worker started; connect your queue consumer here.");
        setInterval(() => undefined, 60_000);
        """, to: root, relativePath: "apps/worker/src/worker.ts", created: &created)
        for version in ["22", "24"] {
            try writeIfMissing("""
            {
              "name": "aiguru-node\(version)-sample",
              "private": true,
              "scripts": { "start": "node server.mjs" },
              "engines": { "node": ">=\(version) <\(Int(version)! + 1)" }
            }
            """, to: root, relativePath: "apps/node\(version)/package.json", created: &created)
            try writeIfMissing("""
            import { createServer } from "node:http";
            const port = Number(process.env.PORT ?? 3000);
            createServer((_request, response) => {
              response.writeHead(200, { "content-type": "application/json; charset=utf-8" });
              response.end(JSON.stringify({ ok: true, service: "node\(version)", runtime: process.version }));
            }).listen(port, "0.0.0.0", () => console.log(`Node \(version) sample listening on ${port}`));
            """, to: root, relativePath: "apps/node\(version)/server.mjs", created: &created)
        }
        try writeIfMissing("<?php echo 'PHP-FPM is ready';\n", to: root, relativePath: "apps/php/index.php", created: &created)
        try writeIfMissing(nginxConfiguration(serverLabel: "primary"), to: root, relativePath: "infra/nginx/nginx-primary-runtime-v4.conf", created: &created)
        try writeIfMissing(nginxConfiguration(serverLabel: "secondary"), to: root, relativePath: "infra/nginx/nginx-secondary-runtime-v4.conf", created: &created)
        try writeIfMissing("""
        .:53 {
          errors
          health :8080
          ready :8181
          cache 30
          reload
          forward . /etc/resolv.conf
        }
        """, to: root, relativePath: "infra/dns/Corefile", created: &created)
        try writeIfMissing("""
        # DNS compatibility layer

        CoreDNS 在容器内部监听 TCP/UDP 53。内置开发模板仅将其发布到宿主机
        `127.0.0.1:5354`，避免占用 Apple Container 内置 DNS 使用的 1053/2053。

        Kubernetes 部署使用集群自己的 CoreDNS Service（通常为 ClusterIP:53）；
        不应将 Kubernetes CoreDNS 直接绑定到 macOS 的 1053/2053。
        """, to: root, relativePath: "infra/dns/README.md", created: &created)
        try createEmptyFileIfMissing(to: root, relativePath: "infra/ssh/authorized_keys", created: &created)
        try writeIfMissing("""
        # SSH Bastion

        将允许登录的 SSH 公钥逐行写入 `authorized_keys`。模板默认关闭密码登录和 sudo，
        并仅把宿主机 `127.0.0.1:2222` 发布到 Bastion 的 2222 端口。

        连接示例：`ssh -p 2222 aiguru@127.0.0.1`
        """, to: root, relativePath: "infra/ssh/README.md", created: &created)
        try writeIfMissing("""
        CREATE USER IF NOT EXISTS 'replicator'@'%' IDENTIFIED BY 'change-replication-password';
        GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'%';
        FLUSH PRIVILEGES;
        """, to: root, relativePath: "infra/mariadb/01-primary-replication.sql", created: &created)
        try writeIfMissing("""
        CREATE USER IF NOT EXISTS '__DB_REPLICATION_USER__'@'%' IDENTIFIED BY '__DB_PASSWORD__';
        GRANT REPLICATION SLAVE ON *.* TO '__DB_REPLICATION_USER__'@'%';
        CREATE USER IF NOT EXISTS '__DB_ROUTER_USER__'@'%' IDENTIFIED BY '__DB_PASSWORD__';
        GRANT ALL PRIVILEGES ON *.* TO '__DB_ROUTER_USER__'@'%' WITH GRANT OPTION;
        FLUSH PRIVILEGES;
        """, to: root, relativePath: "infra/mariadb/01-ha-users.sql", created: &created)
        try writeIfMissing("""
        CREATE USER IF NOT EXISTS 'replicator'@'%' IDENTIFIED BY 'change-root-password';
        GRANT REPLICATION SLAVE ON *.* TO 'replicator'@'%';
        CREATE USER IF NOT EXISTS 'maxscale'@'%' IDENTIFIED BY 'change-root-password';
        GRANT ALL PRIVILEGES ON *.* TO 'maxscale'@'%' WITH GRANT OPTION;
        FLUSH PRIVILEGES;
        """, to: root, relativePath: "infra/mariadb/01-ha-users-runtime-v2.sql", created: &created)
        try writeIfMissing("""
        [maxscale]
        threads=auto
        admin_host=0.0.0.0
        admin_port=8989
        load_persisted_configs=false

        [db-primary]
        type=server
        address=__DB_PRIMARY__
        port=3306
        protocol=MariaDBBackend

        [db-replica-1]
        type=server
        address=__DB_REPLICA_1__
        port=3306
        protocol=MariaDBBackend

        [db-replica-2]
        type=server
        address=__DB_REPLICA_2__
        port=3306
        protocol=MariaDBBackend

        [MariaDB-Monitor]
        type=monitor
        module=mariadbmon
        servers=db-primary,db-replica-1,db-replica-2
        user=maxscale
        password=__DB_PASSWORD__
        monitor_interval=2s
        auto_failover=true
        auto_rejoin=true
        enforce_simple_topology=true
        failcount=3

        [Read-Write-Service]
        type=service
        router=readwritesplit
        servers=db-primary,db-replica-1,db-replica-2
        user=maxscale
        password=__DB_PASSWORD__
        master_failure_mode=fail_on_write
        transaction_replay=true

        [Read-Write-Listener]
        type=listener
        service=Read-Write-Service
        protocol=MariaDBClient
        port=3306

        [Read-Only-Service]
        type=service
        router=readconnroute
        router_options=slave
        servers=db-primary,db-replica-1,db-replica-2
        user=maxscale
        password=__DB_PASSWORD__

        [Read-Only-Listener]
        type=listener
        service=Read-Only-Service
        protocol=MariaDBClient
        port=3307
        """, to: root, relativePath: "infra/mariadb/maxscale-ha.cnf.template", created: &created)

        // Spring Boot 服务使用文件级 bind mount。目录存在并不代表挂载源完整，
        // 因此为尚未构建的服务补一个空 JAR 占位，用户构建后可直接覆盖它。
        for relativePath in [
            "apps/spring-auth/app.jar",
            "apps/spring-order/app.jar",
            "apps/spring-gateway/app.jar"
        ] {
            try createEmptyFileIfMissing(to: root, relativePath: relativePath, created: &created)
        }
        for (service, className) in [
            ("spring-auth", "AuthApplication"),
            ("spring-order", "OrderApplication"),
            ("spring-gateway", "GatewayApplication")
        ] {
            try generateSpringProject(service: service, className: className, root: root, created: &created)
        }
        try writeIfMissing("""
        # Spring Boot 构建产物

        三个 `app.jar` 初始为空，仅用于保证 bind mount 的来源类型始终为文件。
        模板会让空 JAR 容器进入“等待构建产物”状态而不崩溃；替换为真实可执行
        Spring Boot JAR 后，重启或续建应用集群即可运行。

        - `apps/spring-auth/app.jar`
        - `apps/spring-order/app.jar`
        - `apps/spring-gateway/app.jar`
        """, to: root, relativePath: "apps/SPRING_ARTIFACTS.md", created: &created)

        return created
    }

    private static func writeIfMissing(_ content: String, to root: URL, relativePath: String, created: inout [String]) throws {
        let fileURL = root.appendingPathComponent(relativePath)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        created.append(relativePath)
    }

    private static func createEmptyFileIfMissing(to root: URL, relativePath: String, created: inout [String]) throws {
        let fileURL = root.appendingPathComponent(relativePath)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try Data().write(to: fileURL, options: .atomic)
        created.append(relativePath)
    }

    private static func nginxConfiguration(serverLabel: String) -> String {
        """
        worker_processes auto;
        events { worker_connections 1024; }
        http {
          include /etc/nginx/mime.types;
          default_type application/octet-stream;
          access_log /dev/stdout;
          error_log /dev/stderr notice;
          upstream api_backend {
            server ${API_HOST}:3000 max_fails=3 fail_timeout=10s;
          }
          server {
            listen 80;
            server_name _;
            add_header X-Aiguru-Edge \(serverLabel) always;
            root /usr/share/nginx/html;
            index index.html index.php;
            location ^~ /img/ { alias /data/img/; }
            location /api/ {
              proxy_pass http://api_backend/;
              proxy_http_version 1.1;
              proxy_set_header Host $host;
              proxy_set_header X-Real-IP $remote_addr;
              proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
              proxy_set_header X-Forwarded-Proto $scheme;
              proxy_set_header Upgrade $http_upgrade;
              proxy_set_header Connection "upgrade";
            }
            location ~ \\.php$ {
              root /var/www/html;
              try_files $uri =404;
              include /etc/nginx/fastcgi_params;
              fastcgi_param SCRIPT_FILENAME /var/www/html$fastcgi_script_name;
              fastcgi_param DOCUMENT_ROOT /var/www/html;
              fastcgi_pass ${PHP_FPM_HOST}:9000;
              fastcgi_connect_timeout 5s;
              fastcgi_read_timeout 60s;
            }
            location = / {
              try_files /index.html @php_index;
            }
            location @php_index {
              include /etc/nginx/fastcgi_params;
              fastcgi_param SCRIPT_FILENAME /var/www/html/index.php;
              fastcgi_param DOCUMENT_ROOT /var/www/html;
              fastcgi_pass ${PHP_FPM_HOST}:9000;
              fastcgi_connect_timeout 5s;
              fastcgi_read_timeout 60s;
            }
            location / { try_files $uri $uri/ /index.html; }
          }
        }
        stream {
          upstream tcp_api { server ${API_HOST}:3000; }
          server { listen 9000; proxy_connect_timeout 5s; proxy_timeout 1h; proxy_pass tcp_api; }
        }
        """
    }

    private static func generateSpringProject(
        service: String,
        className: String,
        root: URL,
        created: inout [String]
    ) throws {
        let sourceDirectory = "apps/\(service)/src/main/java/cc/aiguru/sample"
        let resourcesDirectory = "apps/\(service)/src/main/resources"
        for directory in [sourceDirectory, resourcesDirectory] {
            let url = root.appendingPathComponent(directory, isDirectory: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                created.append(directory + "/")
            }
        }
        try writeIfMissing("""
        <?xml version="1.0" encoding="UTF-8"?>
        <project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/POM/4.0.0 https://maven.apache.org/xsd/maven-4.0.0.xsd">
          <modelVersion>4.0.0</modelVersion>
          <parent>
            <groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-parent</artifactId><version>3.4.5</version><relativePath/>
          </parent>
          <groupId>cc.aiguru.sample</groupId><artifactId>\(service)</artifactId><version>0.1.0</version>
          <properties><java.version>21</java.version></properties>
          <dependencies><dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-web</artifactId></dependency></dependencies>
          <build>
            <directory>${project.basedir}</directory><finalName>app</finalName>
            <plugins><plugin><groupId>org.springframework.boot</groupId><artifactId>spring-boot-maven-plugin</artifactId></plugin></plugins>
          </build>
        </project>
        """, to: root, relativePath: "apps/\(service)/pom.xml", created: &created)
        try writeIfMissing("""
        package cc.aiguru.sample;

        import java.util.Map;
        import org.springframework.boot.SpringApplication;
        import org.springframework.boot.autoconfigure.SpringBootApplication;
        import org.springframework.web.bind.annotation.GetMapping;
        import org.springframework.web.bind.annotation.RestController;

        @SpringBootApplication
        @RestController
        public class \(className) {
            public static void main(String[] args) { SpringApplication.run(\(className).class, args); }
            @GetMapping({"/", "/health"})
            public Map<String, Object> health() { return Map.of("ok", true, "service", "\(service)"); }
        }
        """, to: root, relativePath: "\(sourceDirectory)/\(className).java", created: &created)
        try writeIfMissing("server.port=8080\nspring.application.name=\(service)\n", to: root, relativePath: "\(resourcesDirectory)/application.properties", created: &created)
    }
}
