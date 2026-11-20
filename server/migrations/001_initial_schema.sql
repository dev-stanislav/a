-- Phantom Court Online — Phase 10 Initial PostgreSQL 16 Schema (Idempotent)

CREATE TABLE IF NOT EXISTS players (
    id UUID PRIMARY KEY,
    username TEXT UNIQUE NOT NULL,
    archetype_fav TEXT NOT NULL DEFAULT 'all_rounder',
    rating DOUBLE PRECISION NOT NULL DEFAULT 1500.0,
    rd DOUBLE PRECISION NOT NULL DEFAULT 350.0,
    volatility DOUBLE PRECISION NOT NULL DEFAULT 0.06,
    wins INT NOT NULL DEFAULT 0,
    losses INT NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS seasonal_stats (
    player_id UUID REFERENCES players(id) ON DELETE CASCADE,
    season_id INT NOT NULL,
    matches_played INT NOT NULL DEFAULT 0,
    wins INT NOT NULL DEFAULT 0,
    losses INT NOT NULL DEFAULT 0,
    points_scored INT NOT NULL DEFAULT 0,
    assists INT NOT NULL DEFAULT 0,
    rebounds INT NOT NULL DEFAULT 0,
    blocks INT NOT NULL DEFAULT 0,
    steals INT NOT NULL DEFAULT 0,
    zone_activations INT NOT NULL DEFAULT 0,
    peak_rating DOUBLE PRECISION NOT NULL DEFAULT 1500.0,
    PRIMARY KEY (player_id, season_id)
);

CREATE TABLE IF NOT EXISTS matches (
    id UUID PRIMARY KEY,
    season_id INT NOT NULL DEFAULT 1,
    mode TEXT NOT NULL,
    team_a_score INT NOT NULL,
    team_b_score INT NOT NULL,
    winner_team SMALLINT NOT NULL,
    duration_sec INT NOT NULL,
    played_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS match_participants (
    match_id UUID REFERENCES matches(id) ON DELETE CASCADE,
    player_id UUID REFERENCES players(id) ON DELETE CASCADE,
    team SMALLINT NOT NULL,
    archetype TEXT NOT NULL,
    points INT NOT NULL DEFAULT 0,
    assists INT NOT NULL DEFAULT 0,
    rebounds INT NOT NULL DEFAULT 0,
    blocks INT NOT NULL DEFAULT 0,
    steals INT NOT NULL DEFAULT 0,
    zone_activations INT NOT NULL DEFAULT 0,
    rating_before DOUBLE PRECISION NOT NULL,
    rating_after DOUBLE PRECISION NOT NULL,
    rating_delta DOUBLE PRECISION NOT NULL,
    PRIMARY KEY (match_id, player_id)
);

CREATE INDEX IF NOT EXISTS idx_players_rating_desc ON players (rating DESC, wins DESC);
CREATE INDEX IF NOT EXISTS idx_players_username_lower ON players (LOWER(username));
CREATE INDEX IF NOT EXISTS idx_match_participants_player ON match_participants (player_id);
CREATE INDEX IF NOT EXISTS idx_matches_played_at_desc ON matches (played_at DESC);
