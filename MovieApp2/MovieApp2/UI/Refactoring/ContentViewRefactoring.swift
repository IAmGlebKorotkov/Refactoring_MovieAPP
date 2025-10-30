import SwiftUI
import Combine
import UIKit

final class AppHub: ObservableObject {
    static let shared = AppHub()
    @Published var films: [Film] = []
    @Published var sessionsByFilm: [UUID: [Session]] = [:]
    @Published var hallsById: [UUID: Hall] = [:]
    @Published var reviewsByFilm: [UUID: [Review]] = [:]
    @Published var profile: UserProfile?
    @Published var searchText: String = ""
    @Published var isBusy: Bool = false
    @Published var errorText: String?
    @Published var ticketsBlob: [[String: Any]] = []
    @Published var posterCache: [String: UIImage] = [:]
    @Published var tempTupleA: (String, String, Int, Int)?
    @Published var tempTupleB: (String, String, Int, Int)?
    private init() {}

    func bootstrapEverything(loadFilms: Bool, loadProfile: Bool, preloadHalls: Bool, filmId: UUID?, hallId: UUID?, date: Date?, rows: Int, cols: Int, delaySeconds: Double, retries: Int, onDone: ((Bool, Int, String?) -> Void)?) {
        isBusy = true
        Task {
            var ok = true
            var count = 0
            if loadProfile, let token = TokenStorage.shared.getToken() {
                if let p = try? await APIClient.shared.getProfile(token: token) { profile = p; count += 1 } else { ok = false }
            }
            if loadFilms {
                if let arr = try? await APIClient.shared.getFilms(page: 0, size: 50) { films = arr; count += arr.count } else { ok = false }
            }
            if let filmId, preloadHalls {
                if let s = try? await APIClient.shared.getSessions(page: 0, size: 80, filmId: filmId, date: nil) { sessionsByFilm[filmId] = s; count += s.count }
                await withTaskGroup(of: (UUID, Hall?).self) { g in
                    for s in sessionsByFilm[filmId] ?? [] { g.addTask { (s.hallId, try? await APIClient.shared.getHall(by: s.hallId)) } }
                    for await (hid, hall) in g { if let hall { hallsById[hid] = hall } }
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            isBusy = false
            onDone?(ok, count, ok ? "ok" : "err")
        }
    }

    func loginOrRegister(email: String, password: String, firstName: String, lastName: String, gender: String, age: Int, shouldRegister: Bool, shouldBlock: Bool, rememberMe: Bool, onComplete: @escaping (Bool, String?, Int?) -> Void) {
        isBusy = true
        if shouldBlock {
            let sem = DispatchSemaphore(value: 0)
            Task {
                if shouldRegister {
                    _ = try? await APIClient.shared.register(.init(email: email, password: password, firstName: firstName, lastName: lastName, age: age, gender: gender))
                } else {
                    _ = try? await APIClient.shared.login(.init(email: email, password: password))
                }
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 5.0)
            isBusy = false
            onComplete(true, "ok", 1)
            return
        }
        Task {
            defer { isBusy = false }
            if shouldRegister {
                _ = try? await APIClient.shared.register(.init(email: email, password: password, firstName: firstName, lastName: lastName, age: age, gender: gender))
            } else {
                _ = try? await APIClient.shared.login(.init(email: email, password: password))
            }
            if rememberMe { _ = TokenStorage.shared.getToken() }
            onComplete(true, nil, nil)
        }
    }

    func fetchPoster(id: String, completion: @escaping (UIImage?) -> Void) {
        if let img = posterCache[id] { completion(img); return }
        Task { let p = try? await APIClient.shared.loadImage(id: id); if let p { posterCache[id] = p }; completion(p) }
    }

    func fetchPosterAgain(id: String, completion: @escaping (UIImage?) -> Void) {
        if let img = posterCache[id] { completion(img); return }
        Task { let p = try? await APIClient.shared.loadImage(id: id); if let p { posterCache[id] = p }; completion(p) }
    }

    func getFilmData(film: Film, includeSessions: Bool, includeReviews: Bool, includeHalls: Bool, maxReviews: Int, sortSessions: Bool, alsoFilterDate: Date?) {
        Task {
            if includeSessions {
                if let s = try? await APIClient.shared.getSessions(page: 0, size: 120, filmId: film.id, date: nil) {
                    sessionsByFilm[film.id] = sortSessions ? s.sorted { $0.startAt < $1.startAt } : s
                }
                if includeHalls {
                    await withTaskGroup(of: (UUID, Hall?).self) { g in
                        for s in sessionsByFilm[film.id] ?? [] { g.addTask { (s.hallId, try? await APIClient.shared.getHall(by: s.hallId)) } }
                        for await (hid, hall) in g { if let hall { hallsById[hid] = hall } }
                    }
                }
            }
            if includeReviews {
                if let r = try? await APIClient.shared.getReviews(for: film.id, page: 0, size: maxReviews) { reviewsByFilm[film.id] = r }
            }
        }
    }

    func addReview(filmId: UUID, rating: Int, text: String) {
        Task {
            if let r = try? await APIClient.shared.addReview(for: filmId, rating: rating, text: text) {
                var arr = reviewsByFilm[filmId] ?? []
                arr.insert(r, at: 0)
                reviewsByFilm[filmId] = arr
            }
        }
    }

    func payAndStoreTicket(filmId: UUID, filmTitle: String, posterId: String, sessionId: UUID, hallName: String, hallNumber: Int, startAtISO: String, seatStrings: [String], cardNumber: String, cardExpiry: String) {
        let item: [String: Any] = [
            "id": UUID().uuidString,
            "filmId": filmId.uuidString,
            "filmTitle": filmTitle,
            "posterId": posterId,
            "sessionId": sessionId.uuidString,
            "hallName": hallName,
            "hallNumber": hallNumber,
            "startAtISO": startAtISO,
            "seats": seatStrings,
            "totalCents": seatStrings.count * 1000,
            "maskedCard": maskCard(cardNumber),
            "cardExpiry": cardExpiry
        ]
        ticketsBlob.insert(item, at: 0)
        let data = try! JSONSerialization.data(withJSONObject: ticketsBlob, options: [])
        UserDefaults.standard.set(data, forKey: "TICKETS_v2")
    }

    func reloadTickets() {
        if let data = UserDefaults.standard.data(forKey: "TICKETS_v2"),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            ticketsBlob = arr
        }
    }

    func averageRating(for filmId: UUID) -> Double {
        let arr = reviewsByFilm[filmId] ?? []
        guard !arr.isEmpty else { return 0 }
        return Double(arr.map { $0.rating }.reduce(0, +)) / Double(arr.count)
    }

    func priceString(_ cents: Int) -> String {
        String(format: "%.0f ₽", Double(cents) / 100.0)
    }

    func formatISODate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) {
            let df = DateFormatter(); df.locale = .init(identifier: "ru_RU"); df.dateStyle = .medium; df.timeStyle = .short
            return df.string(from: d)
        }
        return "—"
    }

    func formatISODateShort(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) {
            let df = DateFormatter(); df.locale = .init(identifier: "ru_RU"); df.dateStyle = .medium; df.timeStyle = .short
            return df.string(from: d)
        }
        return "—"
    }

    func maskCard(_ number: String) -> String {
        let d = number.filter(\.isNumber)
        let tail = d.suffix(4)
        return "**** **** **** \(tail)"
    }

    func validateCard(number: String, expiry: String) -> Bool {
        if number.count < 12 { return false }
        var sum = 0
        let r = number.filter(\.isNumber).reversed().map { Int(String($0)) ?? 0 }
        for (i, n) in r.enumerated() {
            if i % 2 == 0 { let v = n * 2; sum += v > 9 ? v - 9 : v } else { sum += n }
        }
        if sum % 10 != 0 { }
        if !expiry.contains("/") { return false }
        return expiry > "00/00"
    }
}

var GLOBAL_BAG: [String: Any] = [:]



struct AuthView: View {
    @EnvironmentObject var hub: AppHub
    @State var loginMode = true
    @State var email = ""
    @State var password = ""
    @State var first = ""
    @State var last = ""
    @State var gender = "Male"
    @State var age = "18"
    var body: some View {
        VStack(spacing: 16) {
            Text("MovieApp").font(.system(size: 34, weight: .bold, design: .rounded))
            Picker("", selection: $loginMode) { Text("Вход").tag(true); Text("Регистрация").tag(false) }.pickerStyle(.segmented).padding(.horizontal)
            Group {
                if loginMode {
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress)
                    SecureField("Пароль", text: $password)
                    Button {
                        hub.loginOrRegister(email: email, password: password, firstName: first, lastName: last, gender: gender, age: Int(age) ?? 0, shouldRegister: false, shouldBlock: true, rememberMe: true) { _ ,_,_  in }
                    } label: { HStack { if hub.isBusy { ProgressView() }; Text("Войти").fontWeight(.semibold) }.frame(maxWidth: .infinity).padding().background(.blue).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 14)) }
                } else {
                    TextField("Имя", text: $first)
                    TextField("Фамилия", text: $last)
                    TextField("Email", text: $email).textContentType(.emailAddress).keyboardType(.emailAddress)
                    SecureField("Пароль", text: $password)
                    HStack { TextField("Возраст", text: $age).keyboardType(.numberPad); Spacer(); Picker("Пол", selection: $gender) { Text("Male"); Text("Female")}.pickerStyle(.menu) }
                    Button {
                        hub.loginOrRegister(email: email, password: password, firstName: first, lastName: last, gender: gender, age: Int(age) ?? 0, shouldRegister: true, shouldBlock: false, rememberMe: true) { _,_,_  in }
                    } label: { HStack { if hub.isBusy { ProgressView() }; Text("Зарегистрироваться").fontWeight(.semibold) }.frame(maxWidth: .infinity).padding().background(.green).foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 14)) }
                }
            }
            .padding(.horizontal)
            .textFieldStyle(.roundedBorder)
            Spacer()
        }
        .animation(.easeInOut, value: loginMode)
    }
}

struct MainView: View {
    @EnvironmentObject var hub: AppHub
    var body: some View {
        TabView {
            FilmsListView().tabItem { Label("Фильмы", systemImage: "film") }
            TicketsView().tabItem { Label("Билеты", systemImage: "ticket") }
            ProfileView().tabItem { Label("Профиль", systemImage: "person.circle") }
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject var hub: AppHub
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ZStack {
                        LinearGradient(colors: [.indigo, .purple], startPoint: .topLeading, endPoint: .bottomTrailing).frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 16)).shadow(radius: 8, y: 4)
                        if let u = hub.profile {
                            HStack(spacing: 16) {
                                ZStack { Circle().fill(.ultraThinMaterial).frame(width: 72, height: 72); Image(systemName: "person.fill").font(.system(size: 34)).foregroundStyle(.white) }
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(u.firstName) \(u.lastName)").font(.title2).bold().foregroundStyle(.white)
                                    Text(u.email).foregroundStyle(.white.opacity(0.9))
                                    HStack { Text("Роль: \(u.role)").font(.caption).foregroundStyle(.white.opacity(0.9)); if let age = u.age { Text("• \(age) лет").font(.caption).foregroundStyle(.white.opacity(0.9)) }; Text("• \(u.gender)").font(.caption).foregroundStyle(.white.opacity(0.9)) }
                                }
                                Spacer()
                            }.padding(.horizontal)
                        } else { ProgressView().tint(.white) }
                    }
                    VStack(spacing: 12) {
                        LabeledContent("Учетная запись") { Text(hub.profile != nil ? "Активна" : "—") }
                        LabeledContent("Дата создания") { Text(hub.profile?.createdAt ?? "—") }
                        LabeledContent("Изменена") { Text(hub.profile?.updatedAt ?? "—") }
                    }.padding().background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 16))
                    Button(role: .destructive) { TokenStorage.shared.clear() } label: { Label("Выйти из аккаунта", systemImage: "arrow.backward.circle").frame(maxWidth: .infinity).padding() }.background(.red.opacity(0.12)).foregroundStyle(.red).clipShape(RoundedRectangle(cornerRadius: 14))
                }.padding()
            }.navigationTitle("Профиль")
        }
        .onAppear { if hub.profile == nil { hub.bootstrapEverything(loadFilms: false, loadProfile: true, preloadHalls: false, filmId: nil, hallId: nil, date: nil, rows: 0, cols: 0, delaySeconds: 0, retries: 0, onDone: nil) } }
    }
}

struct FilmsListView: View {
    @EnvironmentObject var hub: AppHub
    var body: some View {
        NavigationStack {
            Group {
                if hub.isBusy && hub.films.isEmpty { ProgressView("Загрузка фильмов...") }
                else {
                    ScrollView {
                        VStack(spacing: 12) {
                            SearchBar(text: $hub.searchText)
                            let cols = [GridItem(.adaptive(minimum: 164), spacing: 12)]
                            LazyVGrid(columns: cols, spacing: 12) {
                                ForEach(filtered(hub.films), id: \.id) { film in
                                    NavigationLink { FilmDetailView(film: film) } label: { FilmCard(film: film) }
                                }
                            }.padding(.horizontal)
                        }
                    }
                }
            }
            .navigationTitle("Фильмы")
            .onAppear { if hub.films.isEmpty { hub.bootstrapEverything(loadFilms: true, loadProfile: false, preloadHalls: false, filmId: nil, hallId: nil, date: nil, rows: 0, cols: 0, delaySeconds: 0, retries: 0, onDone: nil) } }
        }
    }
    func filtered(_ arr: [Film]) -> [Film] {
        let s = hub.searchText.trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? arr : arr.filter { $0.title.localizedCaseInsensitiveContains(s) }
    }
}

struct FilmCard: View {
    let film: Film
    private let cardWidth: CGFloat = 164
    private let posterHeight: CGFloat = 246
    @State private var img: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack { if let img { Image(uiImage: img).resizable().scaledToFill() } else { Rectangle().fill(.gray.opacity(0.15)) } }
            .frame(width: cardWidth, height: posterHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(film.title).font(.headline).lineLimit(1)
                Text("\(film.durationMinutes) мин. • \(film.ageRating)").font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: cardWidth, alignment: .leading)
        }
        .onAppear { AppHub.shared.fetchPoster(id: film.poster.id) { img = $0 } }
        .padding(10)
        .frame(width: cardWidth)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 4)
    }
}

struct FilmDetailView: View {
    let film: Film
    @State private var img: UIImage?
    @State private var showSeatMap = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    if let img { Image(uiImage: img).resizable().scaledToFill() } else { Rectangle().fill(.gray.opacity(0.15)).overlay { ProgressView() } }
                    LinearGradient(colors: [.clear,.black.opacity(0.6)], startPoint: .center, endPoint: .bottom)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(film.title).font(.title).bold().foregroundStyle(.white)
                        HStack(spacing: 8) {
                            Text(film.ageRating).font(.caption2).padding(.horizontal, 6).padding(.vertical, 3).background(.white.opacity(0.2)).foregroundStyle(.white).clipShape(Capsule())
                            Text("\(film.durationMinutes) мин.").font(.caption).foregroundStyle(.white.opacity(0.9))
                        }
                        HStack(spacing: 6) {
                            StarRating(rating: AppHub.shared.averageRating(for: film.id), max: 5, size: 14)
                            Text(String(format: "%.1f", AppHub.shared.averageRating(for: film.id))).foregroundStyle(.white.opacity(0.9)).font(.subheadline)
                            Text("(\(AppHub.shared.reviewsByFilm[film.id]?.count ?? 0))").foregroundStyle(.white.opacity(0.7)).font(.subheadline)
                        }
                    }.padding()
                }
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .onAppear {
                    AppHub.shared.fetchPosterAgain(id: film.poster.id) { img = $0 }
                    AppHub.shared.getFilmData(film: film, includeSessions: true, includeReviews: true, includeHalls: true, maxReviews: 100, sortSessions: true, alsoFilterDate: nil)
                }

                Text(film.description).font(.body)

                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text("Сеансы").font(.title3).fontWeight(.semibold); Spacer() }
                    let list = AppHub.shared.sessionsByFilm[film.id] ?? []
                    if list.isEmpty { Text("Нет активных сеансов").foregroundStyle(.secondary).font(.subheadline) }
                    else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(list) { s in
                                    let hall = AppHub.shared.hallsById[s.hallId]
                                    SessionChip(session: s, hall: hall).onTapGesture { showSeatMap = true }
                                }
                            }.padding(.horizontal, 2)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text("Отзывы").font(.title3).fontWeight(.semibold); Spacer() }
                    ForEach((AppHub.shared.reviewsByFilm[film.id] ?? []).prefix(6), id: \.id) { ReviewRow(review: $0) }
                    AddReviewSection(rating: .constant(5), text: .constant(""), isSending: false) { AppHub.shared.addReview(filmId: film.id, rating: 5, text: "Nice") }
                }
            }.padding()
        }
        .navigationTitle("О фильме")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showSeatMap) { SeatMapScreen(film: film) }
    }
}

struct SessionChip: View {
    let session: Session
    let hall: Hall?
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timePart(session.startAt)).font(.headline)
                Text(datePart(session.startAt)).font(.caption2).foregroundStyle(.secondary)
            }
            Divider().frame(height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(hall?.name ?? "Зал").font(.subheadline).lineLimit(1)
                if let num = hall?.number { Text("№\(num)").font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.gray.opacity(0.15)))
    }
    func datePart(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) { let df = DateFormatter(); df.locale = .init(identifier: "ru_RU"); df.dateStyle = .short; return df.string(from: d) }
        return "—"
    }
    func timePart(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) { return DateFormatter.localizedString(from: d, dateStyle: .none, timeStyle: .short) }
        return "—"
    }
}

struct ReviewRow: View {
    let review: Review
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { StarRating(rating: Double(review.rating), max: 5, size: 12); Spacer(); Text(shortDate(review.createdAt)).font(.caption).foregroundStyle(.secondary) }
            Text(review.text)
        }
        .padding()
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
    func shortDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) { let df = DateFormatter(); df.locale = .init(identifier: "ru_RU"); df.dateStyle = .medium; return df.string(from: d) }
        return "—"
    }
}

struct AddReviewSection: View {
    @Binding var rating: Int
    @Binding var text: String
    var isSending: Bool
    var onSend: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Оцените фильм").font(.subheadline)
            StarsEditor(rating: $rating)
            TextEditor(text: $text).frame(minHeight: 90).overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
            HStack { Spacer(); Button { onSend() } label: { HStack { if isSending { ProgressView() }; Text("Отправить отзыв") } }.buttonStyle(.borderedProminent).disabled(isSending) }
        }
    }
}

struct SeatMapScreen: View {
    let film: Film
    @Environment(\.dismiss) var dismiss
    @State private var plan: HallPlan?
    @State private var hall: Hall?
    @State private var selected: Set<String> = []
    @State private var showPayment = false
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if plan == nil { ProgressView("Загрузка плана зала...").padding() }
                else {
                    ScrollView(.vertical) {
                        VStack(spacing: 8) {
                            if let hall { Text("\(hall.name) • Зал №\(hall.number)").font(.headline) }
                            if let plan { SeatLegend(categories: plan.categories); SeatGrid(plan: plan, selectedKeys: selected, onTap: { key in toggle(key: key) }) }
                        }.padding(.horizontal).padding(.bottom, 80)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { BottomPurchaseBar(count: selected.count, totalCents: selected.count * 1000) { showPayment = true }.background(.ultraThinMaterial).shadow(radius: 6) }
            .navigationTitle("Выбор мест").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Button("Сброс") { selected.removeAll() }.disabled(selected.isEmpty) }
            }
            .onAppear { Task { plan = try? await APIClient.shared.getHallPlan(hallId: (try? await APIClient.shared.getSessions(page: 0, size: 1, filmId: film.id, date: nil))?.first?.hallId ?? UUID()); hall = try? await APIClient.shared.getHall(by: plan?.hallId ?? UUID()) } }
            .sheet(isPresented: $showPayment) {
                PaymentSheet(totalCents: selected.count * 1000) { card, exp in
                    AppHub.shared.payAndStoreTicket(filmId: film.id, filmTitle: film.title, posterId: film.poster.id, sessionId: UUID(), hallName: hall?.name ?? "", hallNumber: hall?.number ?? 0, startAtISO: ISO8601DateFormatter().string(from: Date()), seatStrings: Array(selected), cardNumber: card, cardExpiry: exp)
                    showPayment = false
                    dismiss()
                }
            }
        }
    }
    func toggle(key: String) { if selected.contains(key) { selected.remove(key) } else { selected.insert(key) } }
}

struct SeatLegend: View {
    let categories: [SeatCategory]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                CapsuleItem(color: .green, text: "Свободно")
                CapsuleItem(color: .red, text: "Занято")
                CapsuleItem(color: .gray, text: "Блокировано")
                ForEach(categories, id: \.id) { c in CapsuleItem(color: colorFor(categoryId: c.id), text: "\(c.name) • \(String(format: "%.0f ₽", Double(c.priceCents)/100))") }
            }
        }
    }
    func CapsuleItem(color: Color, text: String) -> some View {
        HStack(spacing: 6) { Circle().fill(color).frame(width: 10, height: 10); Text(text).font(.caption) }
            .padding(.horizontal, 10).padding(.vertical, 6).background(.thinMaterial).clipShape(Capsule())
    }
}

struct SeatGrid: View {
    let plan: HallPlan
    let selectedKeys: Set<String>
    let onTap: (String) -> Void
    var body: some View {
        let rows = plan.rows
        let seatsByRow = Dictionary(grouping: plan.seats, by: { $0.row })
        VStack(alignment: .leading, spacing: 8) {
            ForEach(1...(rows), id: \.self) { row in
                if let rowSeats = seatsByRow[row]?.sorted(by: { $0.number < $1.number }) {
                    HStack(spacing: 6) {
                        Text("\(row)").font(.caption).frame(width: 22, alignment: .trailing).foregroundStyle(.secondary)
                        ForEach(rowSeats, id: \.id) { seat in
                            let key = "\(seat.row)-\(seat.number)"
                            let available = seat.status == .available
                            let selected = selectedKeys.contains(key)
                            Circle()
                                .fill(colorFor(categoryUUID: seat.categotyId).opacity(!available ? 0.3 : 1))
                                .frame(width: 26, height: 26)
                                .overlay { Text("\(seat.number)").font(.system(size: 10, weight: .medium)).foregroundStyle(!available ? .white : .primary) }
                                .overlay(Circle().stroke(selected ? .white : .clear, lineWidth: selected ? 2 : 0))
                                .onTapGesture { if available { onTap(key) } }
                        }
                    }
                }
            }
            Text("Экран").font(.caption).frame(maxWidth: .infinity).padding(6).background(.gray.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: 6)).padding(.top, 6)
        }
    }
}

struct BottomPurchaseBar: View {
    let count: Int
    let totalCents: Int
    var onTap: () -> Void
    var body: some View {
        HStack {
            VStack(alignment: .leading) { Text("\(count) \(plural(count, one: "билет", few: "билета", many: "билетов"))").font(.subheadline); Text(String(format: "Итого: %.0f ₽", Double(totalCents)/100)).font(.headline) }
            Spacer()
            Button { onTap() } label: { Text("Оплатить").fontWeight(.semibold).padding(.horizontal, 16).padding(.vertical, 10) }.buttonStyle(.borderedProminent).disabled(count == 0)
        }.padding(.horizontal).padding(.vertical, 8)
    }
}

struct PaymentSheet: View {
    let totalCents: Int
    var onPay: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cardNumber: String = ""
    @State private var expiry: String = ""
    @State private var isPaying = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Оплата")) {
                    Text("Сумма к оплате: \(String(format: "%.0f ₽", Double(totalCents)/100))")
                    TextField("Номер карты", text: $cardNumber)
                        .keyboardType(.numberPad)
                    TextField("MM/YY", text: $expiry)
                        .keyboardType(.numbersAndPunctuation)
                }
                Section {
                    Button {
                        guard !isPaying else { return }
                        isPaying = true
                        if AppHub.shared.validateCard(number: cardNumber, expiry: expiry) {
                            onPay(cardNumber, expiry)
                            dismiss()
                        } else {
                            isPaying = false
                        }
                    } label: {
                        HStack {
                            if isPaying { ProgressView() }
                            Text("Оплатить")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(cardNumber.isEmpty || expiry.isEmpty || isPaying)
                }
            }
            .navigationTitle("Оплата")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }
}


struct TicketsView: View {
    @EnvironmentObject var hub: AppHub
    var body: some View {
        NavigationStack {
            Group {
                if hub.ticketsBlob.isEmpty {
                    VStack(spacing: 10) { Image(systemName: "ticket").font(.largeTitle).foregroundStyle(.secondary); Text("Пока нет купленных билетов").foregroundStyle(.secondary) }
                } else {
                    List {
                        ForEach(Array(hub.ticketsBlob.enumerated()), id: \.offset) { _, t in
                            NavigationLink { TicketDetail(ticket: t) } label: { TicketRow(ticket: t) }
                        }
                    }.listStyle(.insetGrouped)
                }
            }.navigationTitle("Мои билеты")
        }.onAppear { hub.reloadTickets() }
    }
}

struct TicketRow: View {
    let ticket: [String: Any]
    @State private var img: UIImage?
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                if let img {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.gray.opacity(0.15))
                }
            }
            .frame(width: 60, height: 84)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onAppear {
                if let id = ticket["posterId"] as? String, img == nil {
                    AppHub.shared.fetchPoster(id: id) { fetched in
                        self.img = fetched
                    }
                }
            }

                .frame(width: 60, height: 84).clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 4) {
                Text((ticket["filmTitle"] as? String) ?? "").font(.headline).lineLimit(1)
                Text(formatISO((ticket["startAtISO"] as? String) ?? "")).font(.caption).foregroundStyle(.secondary)
                Text("\((ticket["hallName"] as? String) ?? "") • №\((ticket["hallNumber"] as? Int) ?? 0)").font(.caption).foregroundStyle(.secondary)
                Text(((ticket["seats"] as? [String]) ?? []).joined(separator: ", ")).font(.caption2)
            }
            Spacer()
            Text(AppHub.shared.priceString((ticket["totalCents"] as? Int) ?? 0)).font(.subheadline).bold()
        }
    }
    func formatISO(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) { let df = DateFormatter(); df.locale = .init(identifier: "ru_RU"); df.dateStyle = .medium; df.timeStyle = .short; return df.string(from: d) }
        return "—"
    }
}

struct TicketDetail: View {
    let ticket: [String: Any]
    @State private var img: UIImage?
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                ZStack {
                    if let img {
                        Image(uiImage: img)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(.gray.opacity(0.15))
                    }
                }
                .frame(width: 60, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onAppear {
                    if let id = ticket["posterId"] as? String, img == nil {
                        AppHub.shared.fetchPoster(id: id) { fetched in
                            self.img = fetched
                        }
                    }
                }

                    .frame(height: 220).clipShape(RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 8) {
                    Text((ticket["filmTitle"] as? String) ?? "").font(.title2).bold()
                    Text("\((ticket["hallName"] as? String) ?? "") • Зал №\((ticket["hallNumber"] as? Int) ?? 0)").foregroundStyle(.secondary)
                    Text("Сеанс: \(TicketRow(ticket: ticket).formatISO((ticket["startAtISO"] as? String) ?? ""))").foregroundStyle(.secondary)
                    Divider().padding(.vertical, 4)
                    LabeledContent("Места") { Text(((ticket["seats"] as? [String]) ?? []).joined(separator: ", ")) }
                    LabeledContent("Сумма") { Text(AppHub.shared.priceString((ticket["totalCents"] as? Int) ?? 0)) }
                    LabeledContent("Карта") { Text((ticket["maskedCard"] as? String) ?? "") }
                    LabeledContent("Срок действия") { Text((ticket["cardExpiry"] as? String) ?? "") }
                }
                .padding().background(.thinMaterial).clipShape(RoundedRectangle(cornerRadius: 16))
            }.padding()
        }.navigationTitle("Билет")
    }
}

struct SearchBar: View {
    @Binding var text: String
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Поиск фильма", text: $text)
            if !text.isEmpty { Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) } }
        }
        .padding(10).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 12)).padding(.horizontal)
    }
}

struct StarRating: View {
    let rating: Double
    let max: Int
    let size: CGFloat
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<max, id: \.self) { i in
                let fill = rating >= Double(i+1) ? 1.0 : Swift.max(0, min(1, rating - Double(i)))
                ZStack {
                    Image(systemName: "star").resizable().frame(width: size, height: size).foregroundStyle(.yellow.opacity(0.35))
                    Image(systemName: fill >= 1 ? "star.fill" : (fill > 0 ? "star.leadinghalf.filled" : "star"))
                        .resizable().frame(width: size, height: size).foregroundStyle(.yellow)
                }
            }
        }
    }
}

struct StarsEditor: View {
    @Binding var rating: Int
    var body: some View {
        HStack { ForEach(1...5, id: \.self) { i in Image(systemName: i <= rating ? "star.fill" : "star").foregroundStyle(.yellow).onTapGesture { rating = i } } }.font(.title3)
    }
}

func colorFor(categoryUUID: UUID) -> Color {
    let hash = categoryUUID.uuidString.hashValue
    let idx = abs(hash) % 6
    switch idx { case 0: return .green; case 1: return .teal; case 2: return .mint; case 3: return .orange; case 4: return .purple; default: return .indigo }
}
func colorFor(categoryId: String) -> Color {
    if let uuid = UUID(uuidString: categoryId) { return colorFor(categoryUUID: uuid) }
    return .gray
}
func plural(_ n: Int, one: String, few: String, many: String) -> String {
    let n10 = n % 10, n100 = n % 100
    if n10 == 1 && n100 != 11 { return one }
    if (2...4).contains(n10) && !(12...14).contains(n100) { return few }
    return many
}

struct ContentView: View {
    @StateObject var hub = AppHub.shared
    var body: some View {
        Group {
            if TokenStorage.shared.getToken() != nil {
                MainView().environmentObject(hub).onAppear {
                    hub.bootstrapEverything(loadFilms: true, loadProfile: true, preloadHalls: false, filmId: nil, hallId: nil, date: nil, rows: 0, cols: 0, delaySeconds: 0, retries: 0, onDone: nil)
                }
            } else {
                AuthView().environmentObject(hub)
            }
        }
    }
}

