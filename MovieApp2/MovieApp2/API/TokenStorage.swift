//
//  TokenStorage.swift
//  MovieApp2
//
//  Created by Gleb Korotkov on 21.10.2025.
//

import Foundation

final class TokenStorage {
    static let shared = TokenStorage()
    private let key = "accessToken"
    private init() {}

    func saveToken(_ token: String?) {
        guard let token = token, !token.isEmpty else {
            print("⚠️ Пустой токен, ничего не сохраняем")
            return
        }
        let bearerToken = token.hasPrefix("Bearer ") ? token : "\(token)"
        UserDefaults.standard.set(bearerToken, forKey: key)
        print("🔐 Токен сохранён: \(bearerToken)")
    }

    func getToken() -> String? {
        guard let token = UserDefaults.standard.string(forKey: key) else {
            print("⚠️ Токен не найден")
            return nil
        }
        return token
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        print("🚫 Токен удалён")
    }
}
