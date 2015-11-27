
## 集群

集群应该由一个主服务器和多个子服务器组成。主服务器负责监听和分发客户端请求，保证子服务器的负载均衡；子服务器负责处理客户端请求。

程序启动时，自动启动主服务器。主服务器负责启动子服务器，和每个子服务器建立管道，以双向通信：

* 主服务器向子服务器传递客户端套接字
* 子服务器向主服务器传递客户端套接字状态

然后主服务器创建套接字，监听客户端请求。

当有客户端请求时，主服务器 `accpet()`，生成客户端套接字。在子服务器中选择负载最低的，然后通过管道将客户端套接字传送给该子服务器，并增加连接数计数。通过管道收到客户端套接字的子服务器，启动 `processClient()` 对客户端进行处理。当对客户端断开连接时，向主服务器发送 `hsClose` 状态。主服务器收到该状态后，减少客户端连接计数。

## AsyncPipeFD

管道，用来在多进程之间收发文件描述符，以及状态信息。

* open - 创建管道对
* close - 关闭一个管道端
* sendHandle - 通过管道发送文件描述符 
* recvHandle - 通过管道接收文件描述符 
* sendState - 通过管道发送文件描述符状态 
* recvState - 通过管道接收文件描述符状态 

## CLuster + Worker

Worker

工作者服务器的抽象。

启动、重启子进程服务器，传送环境变量，向子服务器发送文件描述符，从子服务器接收状态信息。

* id               - 编号
* process          - 所在进程
* pipe             - 管道对，0 号由主服务器使用，1 号复制到子服务器使用 
* connections      - 当前连接数

* initWorker()     - 初始化
* initEnvTable()   - 配置子进程环境变量
* startPrc()       - 启动子进程
* restartPrc()     - 重启子进程
* connections()    - 获取当前连接数
* incConnections() - 增加连接数
* decConnections() - 减少连接数
* sendHandle()     - 通过管道发送文件描述符
* recvState()      - 通过管道接收状态信息
* recvSetting()    - 通过管道接收服务器配置信息
* running()        - 子进程仍在运行？

Cluster

集群管理者的抽象。

调度工作者，保证负载均衡。

* maxConnections    - 最大连接数
* connections       - 当前连接数
* sockTimeout       - 客户端套接字超时时间
* socket            - 服务端套接字
* reuseAddr         - 安全关闭服务器
* workers           - 工作者序列

* getCluster()      - 返回集群管理者
* forkWorkers()     - 创建新的工作者服务器
* acceptClient()    - 监听客户端请求，创建新的客户端套接字
* selectWorker()    - 选择负载最低的工作者服务器
* incConnections()  - 增加连接数
* decConnections()  - 减少连接数
* serve()           - 启动主服务器

## Server

* newAsyncServer    - 创建服务器
* initAsyncPipe()   - 接受管道 
* serve()           - 设定服务器配置信息
* sendSetting       - 通过管道发送服务器配置信息 
* recvHandle        - 通过管道接收客户端套接字
* sendState         - 通过管道发送客户端套接字状态
* processClient     - 处理客户端请求 









