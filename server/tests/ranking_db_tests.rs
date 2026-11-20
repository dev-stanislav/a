use std::net::SocketAddr;

use phantom_court_server::config::ServerConfig;
use phantom_court_server::db::{PostgresStore, RankingStore, DEFAULT_DATABASE_URL, DEFAULT_SEASON_ID};
use phantom_court_server::net::spawn_game_server;
use phantom_court_server::ranking::{
    compute_match_rating_updates, division_for_rating, update_rating, Glicko2Rating, MatchOutcome,
    DEFAULT_RATING, DEFAULT_RD, DEFAULT_VOLATILITY, SYSTEM_TAU,
};
use serde_json::{json, Value};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use uuid::Uuid;

async fn http_json(
    http_addr: SocketAddr,
    method: &str,
    path: &str,
    body: Option<Value>,
) -> (u16, Value) {
    let mut stream = TcpStream::connect(http_addr).await.expect("tcp connect");
    let body_str = body.map(|v| v.to_string()).unwrap_or_default();
    let req = if body_str.is_empty() {
        format!("{method} {path} HTTP/1.1\r\nHost: {http_addr}\r\nConnection: close\r\n\r\n")
    } else {
        format!(
            "{method} {path} HTTP/1.1\r\nHost: {http_addr}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body_str}",
            body_str.len()
        )
    };
    stream.write_all(req.as_bytes()).await.unwrap();
    let mut resp = String::new();
    stream.read_to_string(&mut resp).await.unwrap();
    let status: u16 = resp
        .lines()
        .next()
        .unwrap_or("")
        .split_whitespace()
        .nth(1)
        .and_then(|s| s.parse().ok())
        .unwrap_or(0);
    let body_part = resp.split("\r\n\r\n").nth(1).unwrap_or("");
    let parsed: Value =
        serde_json::from_str(body_part).unwrap_or_else(|_| json!({ "raw": body_part }));
    (status, parsed)
}

#[test]
fn glicko2_mathematical_invariants_and_division_thresholds() {
    // 1. Default new player constants
    let base = Glicko2Rating::default();
    assert_eq!(base.rating, DEFAULT_RATING);
    assert_eq!(base.rd, DEFAULT_RD);
    assert_eq!(base.volatility, DEFAULT_VOLATILITY);

    // 2. Equal-rated 1v1: winner rises, loser falls, RD shrinks for both!
    let p_win = Uuid::new_v4();
    let p_lose = Uuid::new_v4();
    let updates = compute_match_rating_updates(&[(p_win, base)], &[(p_lose, base)], 0);
    let (_, win_after, win_delta) = updates.iter().find(|u| u.0 == p_win).unwrap();
    let (_, lose_after, lose_delta) = updates.iter().find(|u| u.0 == p_lose).unwrap();

    assert!(win_delta > &0.0, "Winner rating must rise (delta={win_delta})");
    assert!(lose_delta < &0.0, "Loser rating must fall (delta={lose_delta})");
    assert!((win_delta + lose_delta).abs() < 1e-6, "Equal-rated 1v1 deltas must be symmetric");
    assert!(win_after.rd < base.rd, "Winner RD must shrink after match");
    assert!(lose_after.rd < base.rd, "Loser RD must shrink after match");

    // 3. Beating a higher-rated opponent yields a strictly larger delta than beating a lower-rated opponent!
    let player = Glicko2Rating::new(1500.0, 150.0, 0.06);
    let strong_opp = Glicko2Rating::new(1850.0, 80.0, 0.06);
    let weak_opp = Glicko2Rating::new(1250.0, 80.0, 0.06);

    let vs_strong = update_rating(
        player,
        &[MatchOutcome {
            opponent: strong_opp,
            score: 1.0,
        }],
        SYSTEM_TAU,
    );
    let vs_weak = update_rating(
        player,
        &[MatchOutcome {
            opponent: weak_opp,
            score: 1.0,
        }],
        SYSTEM_TAU,
    );
    let delta_strong = vs_strong.rating - player.rating;
    let delta_weak = vs_weak.rating - player.rating;
    assert!(
        delta_strong > delta_weak * 2.0,
        "Beating higher-rated opp (+{delta_strong:.2}) must grant much larger delta than weaker opp (+{delta_weak:.2})"
    );

    // 4. RD continues to shrink monotonically across multiple consecutive games
    let mut cur = Glicko2Rating::default();
    let mut prev_rd = cur.rd;
    for i in 0..6 {
        cur = update_rating(
            cur,
            &[MatchOutcome {
                opponent: Glicko2Rating::new(1500.0, 120.0, 0.06),
                score: if i % 2 == 0 { 1.0 } else { 0.0 },
            }],
            SYSTEM_TAU,
        );
        assert!(cur.rd < prev_rd, "RD must shrink on game {}: {} < {}", i + 1, cur.rd, prev_rd);
        prev_rd = cur.rd;
    }

    // 5. Team 3v3 rating update moves all 3 winners up and all 3 losers down
    let team_a: Vec<(Uuid, Glicko2Rating)> = (0..3).map(|_| (Uuid::new_v4(), base)).collect();
    let team_b: Vec<(Uuid, Glicko2Rating)> = (0..3).map(|_| (Uuid::new_v4(), base)).collect();
    let team_updates = compute_match_rating_updates(&team_a, &team_b, 1);
    assert_eq!(team_updates.len(), 6);
    for (id, _, delta) in &team_updates {
        if team_a.iter().any(|(a, _)| a == id) {
            assert!(*delta < 0.0, "Losing team A member must drop rating");
        } else {
            assert!(*delta > 0.0, "Winning team B member must gain rating");
        }
    }

    // 6. Ranked division thresholds: Bronze .. Phantom
    let cases = [
        (950.0, "Bronze", 0, Some(1300.0)),
        (1299.9, "Bronze", 0, Some(1300.0)),
        (1300.0, "Silver", 1, Some(1500.0)),
        (1499.9, "Silver", 1, Some(1500.0)),
        (1500.0, "Gold", 2, Some(1700.0)),
        (1699.9, "Gold", 2, Some(1700.0)),
        (1700.0, "Platinum", 3, Some(1900.0)),
        (1899.9, "Platinum", 3, Some(1900.0)),
        (1900.0, "Diamond", 4, Some(2100.0)),
        (2099.9, "Diamond", 4, Some(2100.0)),
        (2100.0, "Phantom", 5, None),
        (2450.0, "Phantom", 5, None),
    ];
    for (rating, expected_name, expected_tier, expected_next) in cases {
        let info = division_for_rating(rating);
        assert_eq!(info.name, expected_name, "rating {rating}");
        assert_eq!(info.tier_index, expected_tier, "rating {rating}");
        assert_eq!(info.next_threshold, expected_next, "rating {rating}");
        assert!((0.0..=100.0).contains(&info.progress_pct));
        if expected_next.is_none() {
            assert_eq!(info.progress_pct, 100.0);
        }
    }
}

#[tokio::test]
async fn postgres16_persistence_across_reconnection_and_ranking_http_api() {
    let db_url = std::env::var("DATABASE_URL").unwrap_or_else(|_| DEFAULT_DATABASE_URL.to_string());
    let run_tag = &Uuid::new_v4().simple().to_string()[..8];
    let winner_name = format!("P10Ace_{run_tag}");
    let loser_name = format!("P10Rival_{run_tag}");
    let third_name = format!("P10Wing_{run_tag}");

    // 1. Spawn server #1 wired directly to REAL PostgreSQL 16 (NO --ephemeral-db!)
    let server1 = spawn_game_server(ServerConfig::for_postgres_test(db_url.clone()))
        .await
        .expect("Failed to connect to PostgreSQL 16 (run tools\\start_local_pg.ps1 first!)");

    // Verify GET /health reports db_backend = "postgres"
    let (code, health) = http_json(server1.http_addr, "GET", "/health", None).await;
    assert_eq!(code, 200);
    assert_eq!(health["status"], "ok");
    assert_eq!(health["db_backend"], "postgres");
    assert_eq!(health["ephemeral_db"], false);

    // 2. Create 3 profiles via POST /api/profile
    let (c, p_win) = http_json(
        server1.http_addr,
        "POST",
        "/api/profile",
        Some(json!({ "username": winner_name, "archetype_fav": "speedster" })),
    )
    .await;
    assert_eq!(c, 200);
    let win_id = p_win["id"].as_str().unwrap().to_string();
    assert_eq!(p_win["rating"].as_f64().unwrap(), 1500.0);
    assert_eq!(p_win["rd"].as_f64().unwrap(), 350.0);
    assert_eq!(p_win["division"]["name"], "Gold");

    let (c, p_lose) = http_json(
        server1.http_addr,
        "POST",
        "/api/profile",
        Some(json!({ "username": loser_name, "archetype_fav": "powerhouse" })),
    )
    .await;
    assert_eq!(c, 200);
    let lose_id = p_lose["id"].as_str().unwrap().to_string();

    let (c, p_third) = http_json(
        server1.http_addr,
        "POST",
        "/api/profile",
        Some(json!({ "username": third_name, "archetype_fav": "sharpshooter" })),
    )
    .await;
    assert_eq!(c, 200);
    let third_id = p_third["id"].as_str().unwrap().to_string();

    // Verify GET /api/profile/:id works for BOTH UUID and username lookup!
    let (c, by_uuid) = http_json(server1.http_addr, "GET", &format!("/api/profile/{win_id}"), None).await;
    assert_eq!(c, 200);
    assert_eq!(by_uuid["username"], winner_name);
    let (c, by_name) = http_json(server1.http_addr, "GET", &format!("/api/profile/{winner_name}"), None).await;
    assert_eq!(c, 200);
    assert_eq!(by_name["id"], win_id);

    // 3. Record a ranked 1v1 match via POST /api/matches/record
    let (c, rec1) = http_json(
        server1.http_addr,
        "POST",
        "/api/matches/record",
        Some(json!({
            "mode": "1v1",
            "season_id": 1,
            "team_a_score": 21,
            "team_b_score": 14,
            "duration_sec": 172,
            "participants": [
                {
                    "player_id": win_id,
                    "team": 0,
                    "archetype": "speedster",
                    "points": 21,
                    "assists": 2,
                    "rebounds": 4,
                    "blocks": 1,
                    "steals": 3,
                    "zone_activations": 2
                },
                {
                    "player_id": lose_id,
                    "team": 1,
                    "archetype": "powerhouse",
                    "points": 14,
                    "assists": 1,
                    "rebounds": 6,
                    "blocks": 2,
                    "steals": 0,
                    "zone_activations": 1
                }
            ]
        })),
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(rec1["winner_team"], 0);
    let updates1 = rec1["rating_updates"].as_array().unwrap();
    assert_eq!(updates1.len(), 2);
    let u_win = updates1.iter().find(|u| u["player_id"] == win_id).unwrap();
    let u_lose = updates1.iter().find(|u| u["player_id"] == lose_id).unwrap();
    let win_rating_m1 = u_win["rating_after"].as_f64().unwrap();
    let lose_rating_m1 = u_lose["rating_after"].as_f64().unwrap();
    assert!(win_rating_m1 > 1500.0);
    assert!(lose_rating_m1 < 1500.0);
    assert!(u_win["rd_after"].as_f64().unwrap() < 350.0);

    // 4. Verify online room finish auto-records ranked match & updates Glicko-2 for registered players!
    let (c, room) = http_json(
        server1.http_addr,
        "POST",
        "/api/rooms",
        Some(json!({
            "mode": "1v1",
            "is_private": true,
            "fill_bots": false,
            "host_username": winner_name,
            "archetype": "speedster"
        })),
    )
    .await;
    assert_eq!(c, 200);
    let rid = room["room_id"].as_u64().unwrap();
    let rcode = room["room_code"].as_str().unwrap().to_string();
    let m1 = room["member_id"].as_str().unwrap().to_string();

    let (c, join_res) = http_json(
        server1.http_addr,
        "POST",
        "/api/rooms/join",
        Some(json!({ "room_code": rcode, "username": third_name, "archetype": "sharpshooter" })),
    )
    .await;
    assert_eq!(c, 200);
    let m2 = join_res["member_id"].as_str().unwrap().to_string();

    http_json(
        server1.http_addr,
        "POST",
        &format!("/api/rooms/{rid}/ready"),
        Some(json!({ "member_id": m1, "ready": true })),
    )
    .await;
    http_json(
        server1.http_addr,
        "POST",
        &format!("/api/rooms/{rid}/ready"),
        Some(json!({ "member_id": m2, "ready": true })),
    )
    .await;

    let (c, fin) = http_json(
        server1.http_addr,
        "POST",
        &format!("/api/rooms/{rid}/finish"),
        Some(json!({ "score_a": 18, "score_b": 11 })),
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(fin["state"], "PostMatch");
    assert!(
        fin["ranked_record"]["match_id"].is_string(),
        "Finishing online room with registered players must auto-record ranked match"
    );
    let win_rating_m2 = fin["ranked_record"]["rating_updates"]
        .as_array()
        .unwrap()
        .iter()
        .find(|u| u["player_id"] == win_id)
        .unwrap()["rating_after"]
        .as_f64()
        .unwrap();
    assert!(win_rating_m2 > win_rating_m1, "Second win must further increase rating");

    // 5. Shut down server #1 COMPLETELY to prove real PostgreSQL 16 disk durability!
    server1.shutdown().await;

    // 6. Open a brand-new direct PostgresStore connection and verify all data survived!
    let fresh_store = PostgresStore::connect(&db_url)
        .await
        .expect("fresh PostgresStore reconnect");
    let persisted_win = fresh_store
        .get_profile(&win_id)
        .await
        .expect("winner persisted on disk");
    assert_eq!(persisted_win.wins, 2);
    assert_eq!(persisted_win.losses, 0);
    assert!((persisted_win.rating - win_rating_m2).abs() < 1e-4);
    assert_eq!(persisted_win.seasonal_stats.matches_played, 2);
    assert_eq!(persisted_win.seasonal_stats.points_scored, 21);
    assert_eq!(persisted_win.seasonal_stats.steals, 3);
    assert_eq!(persisted_win.seasonal_stats.blocks, 1);
    assert_eq!(persisted_win.seasonal_stats.zone_activations, 2);
    assert!((persisted_win.seasonal_stats.peak_rating - win_rating_m2).abs() < 1e-4);

    let history = fresh_store
        .get_match_history(&win_id, 10)
        .await
        .expect("match history persisted");
    assert_eq!(history.len(), 2);
    assert!(history[0].won);
    assert!(history[1].won);

    let lb = fresh_store
        .get_leaderboard(DEFAULT_SEASON_ID, 200)
        .await
        .expect("leaderboard query");
    let win_pos = lb.iter().position(|e| e.player_id.to_string() == win_id).unwrap();
    let lose_pos = lb.iter().position(|e| e.player_id.to_string() == lose_id).unwrap();
    let third_pos = lb.iter().position(|e| e.player_id.to_string() == third_id).unwrap();
    assert!(
        win_pos < lose_pos && win_pos < third_pos,
        "2-0 winner must rank strictly above 0-1 losers on global leaderboard"
    );

    // 7. Spawn a brand-new server #2 against the SAME PostgreSQL DB and verify HTTP endpoints!
    let server2 = spawn_game_server(ServerConfig::for_postgres_test(db_url))
        .await
        .expect("spawn server2 against PG");

    let (c, prof2) = http_json(server2.http_addr, "GET", &format!("/api/profile/{win_id}"), None).await;
    assert_eq!(c, 200);
    assert_eq!(prof2["wins"], 2);
    assert!((prof2["rating"].as_f64().unwrap() - win_rating_m2).abs() < 1e-4);

    let (c, hist2) = http_json(
        server2.http_addr,
        "GET",
        &format!("/api/profile/{win_id}/history?limit=20"),
        None,
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(hist2["total"], 2);
    assert_eq!(hist2["history"].as_array().unwrap().len(), 2);

    let (c, lb2) = http_json(
        server2.http_addr,
        "GET",
        "/api/leaderboard?season=1&limit=50",
        None,
    )
    .await;
    assert_eq!(c, 200);
    assert_eq!(lb2["season_id"], 1);
    let entries = lb2["entries"].as_array().unwrap();
    assert!(entries.len() >= 3);
    // Verify descending rating order across returned leaderboard
    for pair in entries.windows(2) {
        assert!(pair[0]["rating"].as_f64().unwrap() >= pair[1]["rating"].as_f64().unwrap());
    }

    server2.shutdown().await;
}
