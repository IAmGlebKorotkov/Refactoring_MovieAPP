//
//  APIManager.swift
//  MovieApp2
//
//  Created by Gleb Korotkov on 21.10.2025.
//

@preconcurrency import Alamofire
import Foundation
import UIKit

final class APIClient {
    static let shared = APIClient()
    private let baseURL = "http://localhost:5148"
    
    private let imageCache = NSCache<NSString, UIImage>()
    
    private init() {}
    
    nonisolated func getFilms(page: Int = 0, size: Int = 20) async throws -> [Film] {
        let url = "\(baseURL)/api/films"
        let parameters: Parameters = [
            "page": page,
            "size": size
        ]
        
        do {
            let response = try await AF.request(url, parameters: parameters)
                .validate()
                .serializingDecodable(FilmsResponse.self)
                .value
            
            print("✅ Получено фильмов с сервера: \(response.data.count)")
            response.data.forEach { print("- \($0.title)") }
            
            return response.data
            
        } catch {
            print("❌ Ошибка при запросе фильмов: \(error)")
            throw error
        }
    }
    
    nonisolated func getFilm(by id: String) async throws -> Film {
        let url = "\(baseURL)/api/films/\(id)"
        let token = await TokenStorage.shared.getToken() ?? ""
        let headers: HTTPHeaders = ["Authorization": token]

        print("📡 [APIClient] Запрос фильма по ID")
        print("🔗 URL: \(url)")
        print("🪙 Токен: \(token.isEmpty ? "❌ Нет токена" : token)")


        let dataResponse = await AF.request(url, method: .get, headers: headers)
            .serializingData()
            .response


        if let statusCode = dataResponse.response?.statusCode {
            print("📡 [APIClient] Код ответа: \(statusCode)")
        } else {
            print("⚠️ [APIClient] Нет статус-кода")
        }


        if let data = dataResponse.data,
           let rawString = String(data: data, encoding: .utf8) {
            print("📦 [APIClient] Сырые данные: \(rawString)")
        } else {
            print("⚠️ [APIClient] Data = nil")
            throw URLError(.badServerResponse)
        }


        guard let data = dataResponse.data else {
            print("❌ [APIClient] Нет данных от сервера")
            throw URLError(.badServerResponse)
        }


        do {
            struct FilmResponse: Decodable {
                let data: Film
            }

            let decoded = try JSONDecoder().decode(FilmResponse.self, from: data)
            print("✅ [APIClient] Фильм успешно декодирован: \(decoded.data.title)")
            return decoded.data
        } catch {
            print("❌ [APIClient] Ошибка декодирования фильма: \(error)")

            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, let context):
                    print("🔑 [DecodingError] Отсутствует ключ: \(key.stringValue), \(context.debugDescription)")
                case .typeMismatch(let type, let context):
                    print("🛠 [DecodingError] Несовпадение типа: \(type), \(context.debugDescription)")
                case .valueNotFound(let type, let context):
                    print("⚠️ [DecodingError] Нет значения для типа: \(type), \(context.debugDescription)")
                case .dataCorrupted(let context):
                    print("💥 [DecodingError] Данные повреждены: \(context.debugDescription)")
                @unknown default:
                    print("❓ [DecodingError] Неизвестная ошибка")
                }
            }

            throw error
        }
    }

    
    nonisolated func loadImage(id: String) async throws -> UIImage {
        let url = "\(baseURL)/media/\(id)"
        
        let request = AF.request(url)
        
        request.response { response in
            if let httpResponse = response.response {
                print("📡 Код ответа: \(httpResponse.statusCode)")
                print("📋 Content-Type: \(httpResponse.mimeType ?? "нет данных")")
                print("📏 Content-Length: \(httpResponse.expectedContentLength)")
            }
            if let data = response.data {
                print("📦 Получено \(data.count) байт")
                if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                    let debugFile = docs.appendingPathComponent("debug_image_\(id).png")
                    try? data.write(to: debugFile)
                    print("💾 Сохранено в: \(debugFile.path)")
                }
            } else {
                print("⚠️ Data = nil")
            }
        }

        let data = try await request
            .validate(statusCode: 200..<300)
            .serializingData()
            .value
        
        print("✅ Получено \(data.count) байт от сервера")

        guard let image = UIImage(data: data) else {
            print("❌ Не удалось создать UIImage, сохраняем файл для проверки…")
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                let debugFile = docs.appendingPathComponent("debug_image_\(id).data")
                try? data.write(to: debugFile)
                print("💾 Сырые данные сохранены в: \(debugFile.path)")
            }
            throw AFError.responseValidationFailed(reason: .dataFileNil)
        }

        return image
    }
    
    nonisolated func register(_ request: RegisterRequest) async throws -> AuthResponse {
        let url = "\(baseURL)/api/Auth/register"
        print("📡 Отправляем регистрацию на \(url)")

        let dataResponse = await AF.request(
            url,
            method: .post,
            parameters: request,
            encoder: JSONParameterEncoder.default
        ).serializingData().response

        if let data = dataResponse.data,
           let rawString = String(data: data, encoding: .utf8) {
            print("📦 Ответ сервера (raw): \(rawString)")
        }

        guard let statusCode = dataResponse.response?.statusCode else {
            throw URLError(.badServerResponse)
        }

        print("📡 Статус-код: \(statusCode)")

        if let data = dataResponse.data {
            do {
                let decoded = try JSONDecoder().decode(AuthResponse.self, from: data)
                
                if decoded.success == true {
                    print("✅ Регистрация успешна: \(decoded.message ?? "OK")")
                    await TokenStorage.shared.saveToken(decoded.accesToken)
                    return decoded
                } else {
                    print("⚠️ Сервер ответил ошибкой: \(decoded.message ?? "Неизвестная ошибка")")
                    throw NSError(domain: "API", code: statusCode, userInfo: [NSLocalizedDescriptionKey: decoded.message ?? "Ошибка регистрации"])
                }
            } catch {
                print("❌ Ошибка декодирования JSON: \(error)")
                throw error
            }
        }

        throw AFError.responseValidationFailed(reason: .unacceptableStatusCode(code: statusCode))
    }


    nonisolated func login(_ request: LoginRequest) async throws -> AuthResponse {
        let url = "\(baseURL)/api/Auth/login"
        print("📡 Отправляем вход на \(url)")
        
        let dataResponse = await AF.request(
            url,
            method: .post,
            parameters: request,
            encoder: JSONParameterEncoder.default
        ).serializingData().response

        if let data = dataResponse.data,
           let rawString = String(data: data, encoding: .utf8) {
            print("📦 Ответ сервера (raw): \(rawString)")
        }

        guard let statusCode = dataResponse.response?.statusCode else {
            throw URLError(.badServerResponse)
        }
        print("📡 Статус-код: \(statusCode)")

        guard let data = dataResponse.data else {
            print("❌ [APIClient] Нет данных от сервера")
            throw URLError(.badServerResponse)
        }

        do {
            let decoded = try JSONDecoder().decode(AuthResponse.self, from: data)
            
            if decoded.success == true {
                print("✅ Вход успешен: \(decoded.message ?? "OK")")
                await TokenStorage.shared.saveToken("Bearer \(decoded.accesToken)")
                return decoded
            } else {
                print("⚠️ Сервер ответил ошибкой: \(decoded.message ?? "Неизвестная ошибка")")
                throw NSError(
                    domain: "API",
                    code: statusCode,
                    userInfo: [NSLocalizedDescriptionKey: decoded.message ?? "Ошибка входа"]
                )
            }
        } catch {
            print("❌ Ошибка декодирования JSON: \(error)")
            throw error
        }
    }
    
    
    nonisolated func getProfile(token: String) async throws -> UserProfile {
        let url = "\(baseURL)/api/Users/me"
        let headers: HTTPHeaders = ["Authorization": "\(token)"]

        print("📡 [APIClient] Запрос профиля")
        print("🔗 URL: \(url)")
        print("🪙 Токен: \(token)")

        let dataResponse = await AF.request(url, method: .get, headers: headers)
            .serializingData()
            .response

        if let statusCode = dataResponse.response?.statusCode {
            print("📡 [APIClient] Код ответа: \(statusCode)")
        } else {
            print("⚠️ [APIClient] Нет статус-кода (возможно, сервер не отвечает)")
        }

        if let data = dataResponse.data,
           let rawString = String(data: data, encoding: .utf8) {
            print("📦 [APIClient] Сырые данные: \(rawString)")
        } else {
            print("⚠️ [APIClient] Data = nil")
        }

        guard let data = dataResponse.data else {
            print("❌ [APIClient] Нет данных от сервера")
            throw URLError(.badServerResponse)
        }

        do {
            let decoded = try JSONDecoder().decode(UserProfileResponse.self, from: data)
            print("✅ [APIClient] Профиль успешно декодирован: \(decoded.user.email)")
            return decoded.user
        } catch {
            print("❌ [APIClient] Ошибка декодирования профиля: \(error)")

            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, let context):
                    print("🔑 [DecodingError] Отсутствует ключ: \(key.stringValue), \(context.debugDescription)")
                case .typeMismatch(let type, let context):
                    print("🛠 [DecodingError] Несовпадение типа: \(type), \(context.debugDescription)")
                case .valueNotFound(let type, let context):
                    print("⚠️ [DecodingError] Нет значения для типа: \(type), \(context.debugDescription)")
                case .dataCorrupted(let context):
                    print("💥 [DecodingError] Данные повреждены: \(context.debugDescription)")
                @unknown default:
                    print("❓ [DecodingError] Неизвестная ошибка")
                }
            }

            throw error
        }
    }

    nonisolated func updateProfile(_ request: UpdateProfileRequest, token: String) async throws -> UserProfile {
        let url = "\(baseURL)/api/Users/me"
        let headers: HTTPHeaders = ["Authorization": "Bearer \(token)"]

        let response = try await AF.request(url, method: .put, parameters: request, encoder: JSONParameterEncoder.default, headers: headers)
            .validate()
            .serializingDecodable(UserProfile.self)
            .value

        return response
    }
    
    nonisolated func getSeatCategories(page: Int = 0, size: Int = 20) async throws -> [SeatCategory] {
        let url = "\(baseURL)/api/SeatCategories"
        let headers: HTTPHeaders = ["Authorization": "Bearer \(await TokenStorage.shared.getToken() ?? "")"]
        let parameters: Parameters = ["page": page, "size": size]
        
        print("📡 [APIClient] Запрос категорий мест")
        print("🔗 URL: \(url)")
        print("🪙 Токен: \(headers["Authorization"] ?? "нет")")
        print("📏 Параметры: page=\(page), size=\(size)")

        let dataResponse = await AF.request(url, method: .get, parameters: parameters, headers: headers)
            .serializingData()
            .response

        if let statusCode = dataResponse.response?.statusCode {
            print("📡 [APIClient] Код ответа: \(statusCode)")
        } else {
            print("⚠️ [APIClient] Нет статус-кода")
        }

        if let data = dataResponse.data,
           let rawString = String(data: data, encoding: .utf8) {
            print("📦 [APIClient] Сырые данные: \(rawString)")
        } else {
            print("⚠️ [APIClient] Data = nil")
            throw URLError(.badServerResponse)
        }

        guard let data = dataResponse.data else {
            print("❌ [APIClient] Нет данных от сервера")
            throw URLError(.badServerResponse)
        }

        do {
            let decoded = try JSONDecoder().decode(SeatCategoriesResponse.self, from: data)
            print("✅ [APIClient] Категории успешно декодированы: \(decoded.data.map { $0.name })")
            return decoded.data
        } catch {
            print("❌ [APIClient] Ошибка декодирования категорий: \(error)")
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, let context):
                    print("🔑 [DecodingError] Отсутствует ключ: \(key.stringValue), \(context.debugDescription)")
                case .typeMismatch(let type, let context):
                    print("🛠 [DecodingError] Несовпадение типа: \(type), \(context.debugDescription)")
                case .valueNotFound(let type, let context):
                    print("⚠️ [DecodingError] Нет значения для типа: \(type), \(context.debugDescription)")
                case .dataCorrupted(let context):
                    print("💥 [DecodingError] Данные повреждены: \(context.debugDescription)")
                @unknown default:
                    print("❓ [DecodingError] Неизвестная ошибка")
                }
            }
            throw error
        }
    }

    
    nonisolated func getReviews(for filmId: UUID, page: Int = 0, size: Int = 20) async throws -> [Review] {
        let url = "\(baseURL)/films/\(filmId.uuidString)/reviews"
        let token = await TokenStorage.shared.getToken() ?? ""
        let headers: HTTPHeaders = ["Authorization": token]
        let parameters: Parameters = ["page": page, "size": size]
        
        print("📡 [APIClient] Запрос отзывов для фильма \(filmId)")
        
        let dataResponse = await AF.request(url, method: .get, parameters: parameters, headers: headers)
            .serializingData()
            .response
        
        if let statusCode = dataResponse.response?.statusCode {
            print("📡 [APIClient] Код ответа: \(statusCode)")
        } else {
            print("⚠️ [APIClient] Нет статус-кода")
        }

        if let data = dataResponse.data,
           let rawString = String(data: data, encoding: .utf8) {
            print("📦 [APIClient] Сырые данные: \(rawString)")
        } else {
            print("⚠️ [APIClient] Data = nil")
            throw URLError(.badServerResponse)
        }

        guard let data = dataResponse.data else {
            throw URLError(.badServerResponse)
        }

        do {
            let decoded = try JSONDecoder().decode(ReviewResponse.self, from: data)
            print("✅ [APIClient] Отзывов получено: \(decoded.data.count)")
            return decoded.data
        } catch {
            print("❌ [APIClient] Ошибка декодирования отзывов: \(error)")
            throw error
        }
    }
    
    nonisolated func addReview(for filmId: UUID, rating: Int, text: String) async throws -> Review {
        let url = "\(baseURL)/films/\(filmId.uuidString)/reviews"
        
        guard let token = await TokenStorage.shared.getToken() else {
            throw URLError(.userAuthenticationRequired)
        }
        
        let headers: HTTPHeaders = [
            "Authorization": token,
            "Content-Type": "application/json"
        ]
        
        let body: [String: Any] = [
            "rating": rating,
            "text": text
        ]
        
        print("💬 [APIClient] Отправляем отзыв на фильм \(filmId)")
        print("📦 Тело: \(body)")
        
        let dataResponse = await AF.request(
            url,
            method: .post,
            parameters: body,
            encoding: JSONEncoding.default,
            headers: headers
        )
        .serializingData()
        .response
        
        if let statusCode = dataResponse.response?.statusCode {
            print("📡 [APIClient] Код ответа: \(statusCode)")
        } else {
            print("⚠️ [APIClient] Нет статус-кода")
        }

        guard let data = dataResponse.data else {
            print("⚠️ [APIClient] Нет данных")
            throw URLError(.badServerResponse)
        }

        if let raw = String(data: data, encoding: .utf8) {
            print("📦 Ответ сервера: \(raw)")
        }

        do {
            let decoded = try JSONDecoder().decode(Review.self, from: data)
            print("✅ [APIClient] Отзыв успешно добавлен: \(decoded.id)")
            return decoded
        } catch {
            print("❌ [APIClient] Ошибка декодирования: \(error)")
            throw error
        }
    }
    
    nonisolated func getSessions(
        page: Int = 0,
        size: Int = 20,
        filmId: UUID? = nil,
        date: Date? = nil
    ) async throws -> [Session] {
        let url = "\(baseURL)/sessions"
        guard let token = await TokenStorage.shared.getToken() else {
            throw URLError(.userAuthenticationRequired)
        }
        
        let headers: HTTPHeaders = ["Authorization": token]
        
        var parameters: [String: Any] = ["page": page, "size": size]
        
        if let filmId = filmId {
            parameters["filmId"] = filmId.uuidString
        }
        
        if let date = date {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            parameters["date"] = formatter.string(from: date)
        }
        
        print("🎟 [APIClient] Загружаем сессии: \(parameters)")
        
        let dataResponse = await AF.request(url, method: .get, parameters: parameters, headers: headers)
            .serializingData()
            .response
        
        if let code = dataResponse.response?.statusCode {
            print("📡 [APIClient] Код ответа: \(code)")
        }
        
        guard let data = dataResponse.data else {
            throw URLError(.badServerResponse)
        }
        
        if let raw = String(data: data, encoding: .utf8) {
            print("📦 [APIClient] Сырые данные: \(raw)")
        }
        
        do {
            let decoded = try JSONDecoder().decode(SessionResponse.self, from: data)
            print("✅ [APIClient] Загружено сессий: \(decoded.data.count)")
            return decoded.data
        } catch {
            print("❌ [APIClient] Ошибка декодирования: \(error)")
            throw error
        }
    }
    
    nonisolated func getHallPlan(hallId: UUID) async throws -> HallPlan {
            let url = "\(baseURL)/api/Halls/\(hallId.uuidString)/plan"
        guard let token = await TokenStorage.shared.getToken() else {
                throw URLError(.userAuthenticationRequired)
            }
            
            let headers: HTTPHeaders = ["Authorization": token]
            
            print("🏛️ [APIClient] Запрос плана зала")
            print("🔗 URL: \(url)")
            print("🪙 Токен: \(token.isEmpty ? "❌ Нет токена" : "Есть токен")")

            let dataResponse = await AF.request(url, method: .get, headers: headers)
                .serializingData()
                .response

            if let statusCode = dataResponse.response?.statusCode {
                print("📡 [APIClient] Код ответа: \(statusCode)")
            } else {
                print("⚠️ [APIClient] Нет статус-кода")
            }

            if let data = dataResponse.data,
               let rawString = String(data: data, encoding: .utf8) {
                print("📦 [APIClient] Сырые данные: \(rawString)")
            } else {
                print("⚠️ [APIClient] Data = nil")
                throw URLError(.badServerResponse)
            }

            guard let data = dataResponse.data else {
                print("❌ [APIClient] Нет данных от сервера")
                throw URLError(.badServerResponse)
            }

            do {
                let decoded = try JSONDecoder().decode(HallPlanResponse.self, from: data)
                print("✅ [APIClient] План зала успешно декодирован")
                print("   Зал ID: \(decoded.hallPlan.hallId)")
                print("   Рядов: \(decoded.hallPlan.rows)")
                print("   Мест: \(decoded.hallPlan.seats.count)")
                print("   Категорий: \(decoded.hallPlan.categories.count)")
                
                return decoded.hallPlan
                
            } catch {
                print("❌ [APIClient] Ошибка декодирования плана зала: \(error)")

                if let decodingError = error as? DecodingError {
                    switch decodingError {
                    case .keyNotFound(let key, let context):
                        print("🔑 [DecodingError] Отсутствует ключ: \(key.stringValue), \(context.debugDescription)")
                    case .typeMismatch(let type, let context):
                        print("🛠 [DecodingError] Несовпадение типа: \(type), \(context.debugDescription)")
                    case .valueNotFound(let type, let context):
                        print("⚠️ [DecodingError] Нет значения для типа: \(type), \(context.debugDescription)")
                    case .dataCorrupted(let context):
                        print("💥 [DecodingError] Данные повреждены: \(context.debugDescription)")
                    @unknown default:
                        print("❓ [DecodingError] Неизвестная ошибка")
                    }
                }

                throw error
            }
        }
    
    nonisolated func getHall(by id: UUID) async throws -> Hall {
        let url = "\(baseURL)/api/Halls/\(id.uuidString)"
        guard let token = await TokenStorage.shared.getToken() else {
            throw URLError(.userAuthenticationRequired)
        }
        
        let headers: HTTPHeaders = ["Authorization": token]
        
        print("🏛️ [APIClient] Запрос информации о зале")
        print("🔗 URL: \(url)")
        print("🪙 Токен: \(token.isEmpty ? "❌ Нет токена" : "Есть токен")")
        
        let dataResponse = await AF.request(url, method: .get, headers: headers)
            .serializingData()
            .response
        
        if let statusCode = dataResponse.response?.statusCode {
            print("📡 [APIClient] Код ответа: \(statusCode)")
        } else {
            print("⚠️ [APIClient] Нет статус-кода")
        }
    
        if let data = dataResponse.data,
           let rawString = String(data: data, encoding: .utf8) {
            print("📦 [APIClient] Сырые данные: \(rawString)")
        } else {
            print("⚠️ [APIClient] Data = nil")
            throw URLError(.badServerResponse)
        }
        
        guard let data = dataResponse.data else {
            print("❌ [APIClient] Нет данных от сервера")
            throw URLError(.badServerResponse)
        }
        
        do {
            let decoded = try JSONDecoder().decode(HallResponse.self, from: data)
            print("✅ [APIClient] Информация о зале успешно декодирована")
            print("   Название: \(decoded.hall.name)")
            print("   Номер: \(decoded.hall.number)")
            print("   ID: \(decoded.hall.id)")
            
            return decoded.hall
            
        } catch {
            print("❌ [APIClient] Ошибка декодирования информации о зале: \(error)")
            
            if let decodingError = error as? DecodingError {
                switch decodingError {
                case .keyNotFound(let key, let context):
                    print("🔑 [DecodingError] Отсутствует ключ: \(key.stringValue), \(context.debugDescription)")
                case .typeMismatch(let type, let context):
                    print("🛠 [DecodingError] Несовпадение типа: \(type), \(context.debugDescription)")
                case .valueNotFound(let type, let context):
                    print("⚠️ [DecodingError] Нет значения для типа: \(type), \(context.debugDescription)")
                case .dataCorrupted(let context):
                    print("💥 [DecodingError] Данные повреждены: \(context.debugDescription)")
                @unknown default:
                    print("❓ [DecodingError] Неизвестная ошибка")
                }
            }
            
            throw error
        }
    }
    
    nonisolated func getFilm(by id: UUID) async throws -> Film {
            let url = "\(baseURL)/api/films/\(id.uuidString)"
        let token = await TokenStorage.shared.getToken() ?? ""
            let headers: HTTPHeaders = ["Authorization": token]

            print("🎬 [APIClient] Запрос фильма по ID")
            print("🔗 URL: \(url)")
            print("🪙 Токен: \(token.isEmpty ? "❌ Нет токена" : "Есть токен")")

            let dataResponse = await AF.request(url, method: .get, headers: headers)
                .serializingData()
                .response

            if let statusCode = dataResponse.response?.statusCode {
                print("📡 [APIClient] Код ответа: \(statusCode)")
            } else {
                print("⚠️ [APIClient] Нет статус-кода")
            }

            if let data = dataResponse.data,
               let rawString = String(data: data, encoding: .utf8) {
                print("📦 [APIClient] Сырые данные: \(rawString)")
            } else {
                print("⚠️ [APIClient] Data = nil")
                throw URLError(.badServerResponse)
            }

            guard let data = dataResponse.data else {
                print("❌ [APIClient] Нет данных от сервера")
                throw URLError(.badServerResponse)
            }

            do {
                let decoded = try JSONDecoder().decode(FilmResponse.self, from: data)
                print("✅ [APIClient] Фильм успешно декодирован: \(decoded.data.title)")
                print("   Длительность: \(decoded.data.durationMinutes) мин")
                print("   Возрастной рейтинг: \(decoded.data.ageRating)")
                print("   Постер ID: \(decoded.data.poster.id)")
                
                return decoded.data
            } catch {
                print("❌ [APIClient] Ошибка декодирования фильма: \(error)")

                if let decodingError = error as? DecodingError {
                    switch decodingError {
                    case .keyNotFound(let key, let context):
                        print("🔑 [DecodingError] Отсутствует ключ: \(key.stringValue), \(context.debugDescription)")
                        print("🔍 [DecodingError] Путь кодирования: \(context.codingPath)")
                    case .typeMismatch(let type, let context):
                        print("🛠 [DecodingError] Несовпадение типа: \(type), \(context.debugDescription)")
                        print("🔍 [DecodingError] Путь кодирования: \(context.codingPath)")
                    case .valueNotFound(let type, let context):
                        print("⚠️ [DecodingError] Нет значения для типа: \(type), \(context.debugDescription)")
                    case .dataCorrupted(let context):
                        print("💥 [DecodingError] Данные повреждены: \(context.debugDescription)")
                    @unknown default:
                        print("❓ [DecodingError] Неизвестная ошибка")
                    }
                }

                throw error
            }
        }
    
    nonisolated func getUser(by id: UUID) async throws -> UserProfile {
           let url = "\(baseURL)/api/Users/id"
        guard let token = await TokenStorage.shared.getToken() else {
               throw URLError(.userAuthenticationRequired)
           }
           
           let parameters: Parameters = ["id": id.uuidString]
           let headers: HTTPHeaders = ["Authorization": token]
           
           print("👤 [APIClient] Запрос пользователя по ID")
           print("🔗 URL: \(url)")
           print("🆔 ID пользователя: \(id.uuidString)")
           print("🪙 Токен: \(token.isEmpty ? "❌ Нет токена" : "Есть токен")")

           let dataResponse = await AF.request(
               url,
               method: .get,
               parameters: parameters,
               headers: headers
           )
           .serializingData()
           .response

           if let statusCode = dataResponse.response?.statusCode {
               print("📡 [APIClient] Код ответа: \(statusCode)")
           } else {
               print("⚠️ [APIClient] Нет статус-кода")
           }

           if let data = dataResponse.data,
              let rawString = String(data: data, encoding: .utf8) {
               print("📦 [APIClient] Сырые данные: \(rawString)")
           } else {
               print("⚠️ [APIClient] Data = nil")
               throw URLError(.badServerResponse)
           }

           guard let data = dataResponse.data else {
               print("❌ [APIClient] Нет данных от сервера")
               throw URLError(.badServerResponse)
           }

           do {
               let decoded = try JSONDecoder().decode(UserByIdResponse.self, from: data)
               print("✅ [APIClient] Пользователь успешно декодирован")
               print("   Email: \(decoded.user.email)")
               print("   Имя: \(decoded.user.firstName) \(decoded.user.lastName)")
               print("   Роль: \(decoded.user.role)")
               print("   Возраст: \(decoded.user.age ?? 0)")
               print("   Пол: \(decoded.user.gender)")
               
               return decoded.user
               
           } catch {
               print("❌ [APIClient] Ошибка декодирования пользователя: \(error)")

               if let decodingError = error as? DecodingError {
                   switch decodingError {
                   case .keyNotFound(let key, let context):
                       print("🔑 [DecodingError] Отсутствует ключ: \(key.stringValue), \(context.debugDescription)")
                       print("🔍 [DecodingError] Путь кодирования: \(context.codingPath)")
                   case .typeMismatch(let type, let context):
                       print("🛠 [DecodingError] Несовпадение типа: \(type), \(context.debugDescription)")
                       print("🔍 [DecodingError] Путь кодирования: \(context.codingPath)")
                   case .valueNotFound(let type, let context):
                       print("⚠️ [DecodingError] Нет значения для типа: \(type), \(context.debugDescription)")
                   case .dataCorrupted(let context):
                       print("💥 [DecodingError] Данные повреждены: \(context.debugDescription)")
                   @unknown default:
                       print("❓ [DecodingError] Неизвестная ошибка")
                   }
               }

               throw error
           }
       }
}
