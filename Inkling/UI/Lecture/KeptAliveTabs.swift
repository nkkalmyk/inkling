import SwiftUI

// MARK: Вкладки без пересборки

/// Открытые вкладки лекции: у каждой свой `NSHostingView`, переключение — прозрачность хоста.
/// Если держать вкладки в одном SwiftUI-дереве и прятать прозрачностью, SwiftUI при каждом переключении
/// вынимает AppKit-виды скрытой вкладки из окна и вставляет обратно (списки, веб-вью, редактор),
/// пересобирает список отрисовки и цепочку клавиатурного фокуса — это и был рывок анимации.
struct KeptAliveTabs<Content: View>: NSViewRepresentable {
    let tabs: [LectureTab]
    let active: LectureTab
    /// Данные, от которых зависит содержимое вкладок (лекция). Пока они те же, переключение не трогает
    /// содержимое вкладок вовсе: меняется только видимость и флаг активности.
    let revision: LectureRecord
    @ViewBuilder let content: (LectureTab) -> Content

    final class Coordinator {
        var hosts: [LectureTab: NSHostingView<ActivityRoot>] = [:]
        var activities: [LectureTab: TabActivity] = [:]
        var key: EnvironmentKey?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> Container {
        let view = Container()
        view.autoresizesSubviews = true
        return view
    }

    /// Щелчки получает только видимая вкладка: прозрачные неактивные лежат рядом и не должны их ловить.
    final class Container: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? {
            // point — в координатах суперпредставления; подвидам нужен в своих.
            let local = convert(point, from: superview)
            for host in subviews.reversed() where !host.isHidden && host.alphaValue > 0 {
                if let hit = host.hitTest(local) { return hit }
            }
            return nil
        }
    }

    func updateNSView(_ view: Container, context: Context) {
        let coordinator = context.coordinator
        let environment = context.environment
        // Окружение копируется в хосты целиком; пересобираем их при смене лекции и тех значений окружения,
        // что меняются на ходу (тема, контраст, «Уменьшить движение», размер текста).
        let key = EnvironmentKey(revision: revision, colorScheme: environment.colorScheme,
                                 contrast: environment.colorSchemeContrast,
                                 reduceMotion: environment.accessibilityReduceMotion,
                                 reduceTransparency: environment.accessibilityReduceTransparency,
                                 dynamicTypeSize: environment.dynamicTypeSize,
                                 readingScale: environment.readingScale)
        let revisionChanged = coordinator.key != key
        coordinator.key = key
        for tab in tabs {
            let isActive = tab == active
            let activity = coordinator.activities[tab] ?? TabActivity(isActive: isActive)
            coordinator.activities[tab] = activity
            if activity.isActive != isActive { activity.isActive = isActive }
            let root = { ActivityRoot(activity: activity, content: AnyView(content(tab).environment(\.self, environment))) }
            if let host = coordinator.hosts[tab] {
                if revisionChanged { host.rootView = root() }
            } else {
                let host = NSHostingView(rootView: root())
                host.sizingOptions = []
                host.frame = view.bounds
                host.autoresizingMask = [.width, .height]
                view.addSubview(host)
                coordinator.hosts[tab] = host
            }
            // Неактивная вкладка полностью прозрачна, но не скрыта: скрытый хост при показе заново
            // собирает и отрисовывает AppKit-виды, а прозрачный уже готов. Щелчки, VoiceOver и фокус
            // ей не достаются (Container.hitTest, ActivityRoot, isActiveTab).
            coordinator.hosts[tab]?.alphaValue = isActive ? 1 : 0
        }
        // Фокус не остаётся в ставшей прозрачной вкладке: иначе набор с клавиатуры уходил бы в невидимый редактор.
        if let window = view.window, let responder = window.firstResponder as? NSView,
           let owner = coordinator.hosts.first(where: { responder.isDescendant(of: $0.value) })?.key, owner != active {
            window.makeFirstResponder(coordinator.hosts[active])
        }
    }

    struct EnvironmentKey: Equatable {
        var revision: LectureRecord
        var colorScheme: ColorScheme
        var contrast: ColorSchemeContrast
        var reduceMotion: Bool
        var reduceTransparency: Bool
        var dynamicTypeSize: DynamicTypeSize
        var readingScale: Double
    }
}

/// Видна ли вкладка. Объект, а не значение в rootView: при переключении обновляются только виды,
/// которые читают `\.isActiveTab`, а не всё дерево вкладки.
@Observable
final class TabActivity {
    var isActive: Bool
    init(isActive: Bool) { self.isActive = isActive }
}

struct ActivityRoot: View {
    let activity: TabActivity
    let content: AnyView

    var body: some View {
        // Хост-вид центрирует корень по его собственному размеру: вкладка должна занимать всю область,
        // иначе фон зоны и пустые состояния собираются комком посередине.
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .environment(\.isActiveTab, activity.isActive)
            .accessibilityHidden(!activity.isActive)
    }
}
