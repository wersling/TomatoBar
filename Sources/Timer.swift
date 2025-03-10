import SwiftUI
import ServiceManagement

class TBTimer: ObservableObject {
    // 应用设置，使用 AppStorage 持久化
    @AppStorage("stopAfterBreak") var stopAfterBreak = false          // 休息后停止
    @AppStorage("showTimerInMenuBar") var showTimerInMenuBar = true   // 在菜单栏显示计时器
    @AppStorage("workIntervalLength") var workIntervalLength = 25     // 工作间隔长度（分钟）
    @AppStorage("shortRestIntervalLength") var shortRestIntervalLength = 5    // 短休息间隔长度（分钟）
    @AppStorage("longRestIntervalLength") var longRestIntervalLength = 15     // 长休息间隔长度（分钟）
    @AppStorage("workIntervalsInSet") var workIntervalsInSet = 4      // 每组中的工作间隔数量
    @AppStorage("forceRest") var forceRest = true                     // 强制休息
    @AppStorage("launchAtLogin") var launchAtLogin = true             // 开机启动，默认开启
    // 这个偏好设置是"隐藏的"
    @AppStorage("overrunTimeLimit") var overrunTimeLimit = -60.0      // 超时限制（秒）

    private var stateMachine = TBStateMachine(state: .idle)           // 状态机，初始状态为空闲
    public let player = TBPlayer()                                    // 音效播放器
    @Published public private(set) var consecutiveWorkIntervals: Int = 0  // 连续工作间隔计数
    private var notificationCenter = TBNotificationCenter()           // 通知中心
    private var finishTime: Date!                                     // 计时结束时间
    private var timerFormatter = DateComponentsFormatter()            // 时间格式化器
    @Published var timeLeftString: String = ""                        // 剩余时间字符串
    @Published var timer: DispatchSourceTimer?                        // 计时器
    private var forceRestWindowManager = ForceRestWindowManager.shared // 强制休息窗口管理器
    private var currentBreakIsLong = false
    
    // 统计管理器实例
    private var statsManager = StatsManager.shared
    
    // 工作开始时间
    private var workStartTime: Date?
    
    // 公共方法：获取当前状态
    public var currentState: TBStateMachineStates {
        return stateMachine.state
    }
    
    // 公共方法：判断是否是长休息
    public var isLongRest: Bool {
        return currentState == .rest && currentBreakIsLong
    }

    init() {
        /*
         * 状态图
         *
         *                 start/stop
         *       +--------------+-------------+
         *       |              |             |
         *       |  start/stop  |  timerFired |
         *       V    |         |    |        |
         * +--------+ |  +--------+  | +--------+
         * | idle   |--->| work   |--->| rest   |
         * +--------+    +--------+    +--------+
         *   A                  A        |    |
         *   |                  |        |    |
         *   |                  +--------+    |
         *   |  timerFired (!stopAfterBreak)  |
         *   |             skipRest           |
         *   |                                |
         *   +--------------------------------+
         *      timerFired (stopAfterBreak)
         *
         */
        
        // 设置状态转换处理器
        stateMachine.add_anyToWork(handler: onWorkStart)          // 任何状态到工作状态
        stateMachine.add_workToRest(handler: onWorkFinish)        // 工作状态到休息状态
        stateMachine.add_workToAny(handler: onWorkEnd)            // 工作状态到任何状态
        stateMachine.add_anyToRest(handler: onRestStart)          // 任何状态到休息状态
        stateMachine.add_restToWork(handler: onRestFinish)        // 休息状态到工作状态
        stateMachine.add_anyToIdle(handler: onIdleStart)          // 任何状态到空闲状态
        
        // 记录所有状态转换
        stateMachine.add_anyToAny(handler: {
            let fromState = self.stateMachine.state
            let toState = self.stateMachine.state
            let event = TBLogEventTransition(from: String(describing: fromState), to: String(describing: toState))
            logger.append(event: event)
        })

        // 配置时间格式化器
        timerFormatter.unitsStyle = .positional
        timerFormatter.allowedUnits = [.minute, .second]
        timerFormatter.zeroFormattingBehavior = .pad

        // 设置通知动作处理器
        notificationCenter.setActionHandler(handler: onNotificationAction)

        // 注册 URL 处理
        let aem: NSAppleEventManager = NSAppleEventManager.shared()
        aem.setEventHandler(self,
                            andSelector: #selector(handleGetURLEvent(_:withReplyEvent:)),
                            forEventClass: AEEventClass(kInternetEventClass),
                            andEventID: AEEventID(kAEGetURL))
    }

    // 处理 URL 事件
    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor,
                                 withReplyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.forKeyword(AEKeyword(keyDirectObject))?.stringValue else {
            print("url handling error: cannot get url")
            return
        }
        let url = URL(string: urlString)
        guard url != nil,
              let scheme = url!.scheme,
              let host = url!.host else {
            print("url handling error: cannot parse url")
            return
        }
        guard scheme.caseInsensitiveCompare("tomatobar") == .orderedSame else {
            print("url handling error: unknown scheme \(scheme)")
            return
        }
        switch host.lowercased() {
        case "startstop":
            startStop()
        default:
            print("url handling error: unknown command \(host)")
            return
        }
    }

    // 开始/停止计时器
    func startStop() {
        _ = stateMachine.tryEvent(.startStop)
    }

    // 跳过休息
    func skipRest() {
        // 如果启用了强制休息，不允许跳过
        if !forceRest {
            _ = stateMachine.tryEvent(.skipRest)
        }
    }

    // 更新剩余时间显示
    func updateTimeLeft() {
        timeLeftString = timerFormatter.string(from: Date(), to: finishTime)!
        
        // 更新状态栏时间
        if timer != nil, showTimerInMenuBar {
            TBStatusItem.shared.setTitle(title: timeLeftString)
        } else {
            TBStatusItem.shared.setTitle(title: nil)
        }
        
        // 更新强制休息窗口时间（如果正在显示）
        if forceRest && stateMachine.state == .rest {
            forceRestWindowManager.updateTimeRemaining(timeLeftString)
        }
    }

    // 启动计时器
    private func startTimer(seconds: Int) {
        finishTime = Date().addingTimeInterval(TimeInterval(seconds))

        let queue = DispatchQueue(label: "Timer")
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer!.schedule(deadline: .now(), repeating: .seconds(1), leeway: .never)
        timer!.setEventHandler(handler: onTimerTick)
        timer!.setCancelHandler(handler: onTimerCancel)
        timer!.resume()
    }

    // 停止计时器
    private func stopTimer() {
        timer!.cancel()
        timer = nil
    }

    // 计时器滴答事件处理
    private func onTimerTick() {
        /* 无法从后台线程发布更新 */
        DispatchQueue.main.async { [self] in
            updateTimeLeft()
            let timeLeft = finishTime.timeIntervalSince(Date())
            if timeLeft <= 0 {
                /*
                 机器休眠期间可能会错过滴答声。
                 如果超过超时限制，则停止计时器。
                 */
                if timeLeft < overrunTimeLimit {
                    _ = stateMachine.tryEvent(.startStop)
                } else {
                    _ = stateMachine.tryEvent(.timerFired) { self.stopAfterBreak }
                }
            }
        }
    }

    // 计时器取消事件处理
    private func onTimerCancel() {
        DispatchQueue.main.async { [self] in
            updateTimeLeft()
        }
    }

    // 通知动作处理
    private func onNotificationAction(action: TBNotification.Action) {
        if action == .skipRest && !forceRest && stateMachine.state == .rest {
            skipRest()
        }
    }

    // 工作开始处理
    private func onWorkStart() {
        TBStatusItem.shared.setIcon(name: .work)
        player.playWindup()
        player.startTicking()
        startTimer(seconds: workIntervalLength * 60)
        
        // 记录工作开始时间，用于统计
        workStartTime = Date()
    }

    // 工作完成处理
    private func onWorkFinish() {
        consecutiveWorkIntervals += 1
        player.playDing()
        
        // 计算并记录已完成的工作时间
        if let startTime = workStartTime {
            let workDuration = Date().timeIntervalSince(startTime)
            let workMinutes = Int(workDuration / 60)
            statsManager.recordCompletedPomodoro(workMinutes: workMinutes)
            workStartTime = nil
        }
    }

    // 工作结束处理
    private func onWorkEnd() {
        player.stopTicking()
        workStartTime = nil
    }

    // 休息开始处理
    private func onRestStart() {
        var body = NSLocalizedString("TBTimer.onRestStart.short.body", comment: "Short break body")
        var length = shortRestIntervalLength
        var imgName = NSImage.Name.shortRest
        currentBreakIsLong = false
        
        // 检查是否需要长休息
        if consecutiveWorkIntervals >= workIntervalsInSet {
            body = NSLocalizedString("TBTimer.onRestStart.long.body", comment: "Long break body")
            length = longRestIntervalLength
            imgName = .longRest
            currentBreakIsLong = true
            consecutiveWorkIntervals = 0
            
            // 记录一次长休息
            statsManager.recordLongBreak()
        } else {
            // 记录一次短休息
            statsManager.recordShortBreak()
        }
        
        TBStatusItem.shared.setIcon(name: imgName)
        
        // 根据是否强制休息显示不同的通知
        if forceRest {
            notificationCenter.postNotification(
                title: NSLocalizedString("TBTimer.onRestStart.title", comment: "Rest title"),
                body: body)
            
            // 显示强制休息全屏窗口
            DispatchQueue.main.async { [self] in
                let initialTime = timerFormatter.string(from: TimeInterval(length * 60))!
                forceRestWindowManager.showForceRestWindow(timeRemaining: initialTime, isLongBreak: currentBreakIsLong)
            }
        } else {
            notificationCenter.postNotification(
                title: NSLocalizedString("TBTimer.onRestStart.title", comment: "Rest title"),
                body: body,
                skipButton: NSLocalizedString("TBTimer.onRestStart.skip.title", comment: "Skip button"))
        }
        
        startTimer(seconds: length * 60)
    }

    // 休息完成处理
    private func onRestFinish() {
        // 关闭强制休息窗口
        if forceRest {
            DispatchQueue.main.async {
                self.forceRestWindowManager.closeForceRestWindow()
            }
        }
        
        notificationCenter.postNotification(
            title: NSLocalizedString("TBTimer.onRestFinish.title", comment: "Rest finished title"),
            body: NSLocalizedString("TBTimer.onRestFinish.body", comment: "Rest finished body"))
    }

    // 空闲状态开始处理
    private func onIdleStart() {
        if timer != nil {
            stopTimer()
        }
        
        // 关闭强制休息窗口
        if forceRest {
            DispatchQueue.main.async {
                self.forceRestWindowManager.closeForceRestWindow()
            }
        }
        
        TBStatusItem.shared.setIcon(name: .idle)
    }

    // 设置开机启动状态
    func setLaunchAtLogin(_ enable: Bool) {
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        
        // 对于 macOS 13 及以上版本，使用 SMAppService
        if #available(macOS 13.0, *) {
            let service = SMAppService.mainApp
            do {
                if enable {
                    if service.status != .enabled {
                        try service.register()
                    }
                } else {
                    if service.status == .enabled {
                        try service.unregister()
                    }
                }
            } catch {
                print("无法更改登录项状态: \(error.localizedDescription)")
            }
        } 
        // 对于 macOS 12 及更早版本，使用旧的 SMLoginItemSetEnabled API
        else {
            let success = SMLoginItemSetEnabled(bundleIdentifier as CFString, enable)
            if !success {
                print("无法更改登录项状态：SMLoginItemSetEnabled 失败")
            }
        }
    }
}
