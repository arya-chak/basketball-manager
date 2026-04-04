extends Node

# Match signals
signal match_simulated(result: Dictionary)

# Calendar signals
signal day_advanced(new_date: Dictionary)
signal new_season_started(season: int)
signal offseason_started()

# Team/player signals
signal roster_changed(team_id: int)
signal player_injured(player_id: int, games_out: int)
signal player_developed(player_id: int)

# Personnel signals
signal trade_completed(trade: Dictionary)
signal free_agent_signed(player_id: int, team_id: int)
signal player_waived(player_id: int)
signal draft_pick_made(player_id: int, team_id: int, pick: int)

# Career signals
signal job_offer_received(offer: Dictionary)
signal coach_hired(team_id: int)
signal coach_fired(team_id: int)
signal reputation_changed(new_value: float)

# UI signals
signal screen_change_requested(screen_name: String)
signal notification_posted(message: String, type: String)
