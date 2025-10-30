//
//  FilmModels.swift
//  MovieApp2
//
//  Created by Gleb Korotkov on 21.10.2025.
//

import Foundation

nonisolated(unsafe) struct FilmsResponse: Decodable, Sendable {
    let data: [Film]
    let pagination: Pagination
}

nonisolated(unsafe) struct FilmResponse: Decodable, Sendable {
    let data: Film
}

nonisolated(unsafe) struct Film: Decodable, Sendable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let description: String
    let durationMinutes: Int
    let ageRating: String
    let poster: Poster
    let createdAt: String
    let updatedAt: String

    static func == (lhs: Film, rhs: Film) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}




nonisolated(unsafe) struct Poster: Decodable, Sendable {
    let id: String
    let filename: String
    let contentType: String
    let mediaType: String
    let createdAt: String
    let updatedAt: String
}

nonisolated(unsafe) struct Pagination: Decodable, Sendable {
    let page: Int
    let limit: Int
    let total: Int
    let pages: Int
}

nonisolated(unsafe) struct RegisterRequest: Encodable {
    let email: String
    let password: String
    let firstName: String
    let lastName: String
    let age: Int
    let gender: String
}

nonisolated(unsafe) struct LoginRequest: Encodable {
    let email: String
    let password: String
}


nonisolated(unsafe) struct AuthResponse: Decodable {
    let accesToken: String
    let message: String?
    let success: Bool
}


nonisolated(unsafe) struct UserProfileResponse: Codable {
    let user: UserProfile
}

nonisolated(unsafe) struct UserByIdResponse: Decodable, Sendable {
    let user: UserProfile
}

nonisolated(unsafe) struct UserProfile: Codable, Identifiable {
    let id: String
    var email: String
    var firstName: String
    var lastName: String
    var age: Int?
    var gender: String
    let role: String
    let createdAt: String
    let updatedAt: String
}

nonisolated(unsafe) struct UpdateProfileRequest: Encodable {
    let firstName: String
    let lastName: String
    let email: String
    let gender: String
    let age: Int
}


nonisolated(unsafe) struct UserResponse: Codable {
    let user: UserProfile
}



nonisolated(unsafe) struct SeatCategoriesResponse: Decodable {
    let success: Bool
    let data: [SeatCategory]
    let pagination: Pagination
}

nonisolated(unsafe) struct SeatCategory: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let priceCents: Int
}

nonisolated(unsafe) struct ReviewResponse: Decodable, Sendable {
    let data: [Review]
    let pagination: Pagination
}

nonisolated(unsafe) struct Review: Decodable, Identifiable, Sendable {
    let id: UUID
    let filmId: UUID
    let clientId: UUID
    let rating: Int
    let text: String
    let createdAt: String
}

nonisolated(unsafe) struct SessionResponse: Decodable, Sendable {
    let data: [Session]
    let pagination: Pagination
}

nonisolated(unsafe) struct Session: Decodable, Identifiable, Sendable, Hashable {
    let id: UUID
    let filmId: UUID
    let hallId: UUID
    let startAt: String
    let timeslot: Timeslot

    static func == (lhs: Session, rhs: Session) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

nonisolated(unsafe) struct Timeslot: Decodable, Sendable {
    let start: String
    let end: String
}


nonisolated(unsafe) struct HallPlanResponse: Decodable, Sendable {
    let hallPlan: HallPlan
}

nonisolated(unsafe) struct HallPlan: Decodable, Sendable, Identifiable {
    let hallId: UUID
    let rows: Int
    let seats: [Seat]
    let categories: [SeatCategory]
    
    var id: UUID { hallId }
}

nonisolated(unsafe) struct Seat: Decodable, Sendable, Identifiable, Hashable {
    let id: UUID
    let row: Int
    let number: Int
    let categotyId: UUID 
    let status: SeatStatus
    
    static func == (lhs: Seat, rhs: Seat) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

nonisolated(unsafe) enum SeatStatus: String, Decodable, Sendable {
    case available = "Available"
    case occupied = "Occupied"
    case reserved = "Reserved"
    case blocked = "Blocked"
}


nonisolated(unsafe) struct HallResponse: Decodable, Sendable {
    let hall: Hall
}

nonisolated(unsafe) struct Hall: Decodable, Sendable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let number: Int
    let createdAt: String
    let updatedAt: String
    
    static func == (lhs: Hall, rhs: Hall) -> Bool {
        lhs.id == rhs.id
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
