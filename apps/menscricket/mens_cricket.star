"""
Applet: Mens Cricket
Summary: Display cricket scores
Description: For a selected team, this app shows the scorecard for a current match. If no match in progress, it will display scorecard for a recently completed match. If none of these, it will display the next match details in user's local timezone.
Author: adilansari

v 1.0 - Intial version with T20/ODI match support
"""

load("encoding/json.star", "json")
load("http.star", "http")
load("render.star", "render")
load("schema.star", "schema")
load("time.star", "time")

TEAM_HOME_URL = "https://hs-consumer-api.espncricinfo.com/v1/pages/team/home?lang=en&teamId="
MATCH_URL = "https://hs-consumer-api.espncricinfo.com/v1/pages/match/details?lang=en&seriesId={series_id}&matchId={match_id}&latest=true"
TEAM_HOME_API_CACHE_TTL = 600  # 10 minutes
MATCH_API_CACHE_TTL = 60  # 1 minute
TIME_FORMAT = "2006-01-02T15:04:00.000Z"
DEFAULT_SCREEN = render.Root(
    child = render.WrappedText(
        content = "No match for team. Please choose a different option.",
        font = "tom-thumb",
    ),
)

# Config
DEFAULT_TIMEZONE = "America/New_York"
DEFAULT_TEAM_ID = "40"
DEFAULT_PAST_RESULT_DAYS = 5
ALWAYS_SHOW_FIXTURES_SCHEMA_KEY = "Always"

# Styling
LRG_FONT = "CG-pixel-4x5-mono"
SML_FONT = "CG-pixel-3x5-mono"
BLACK_COLOR = "#222222"
WHITE_COLOR = "#FFFFFF"
CHARCOAL_COLOR = "#36454F"

def main(config):
    tz = config.get("$tz", DEFAULT_TIMEZONE)
    team_id = config.get("team", DEFAULT_TEAM_ID)
    fixture_days = config.get("days_forward", ALWAYS_SHOW_FIXTURES_SCHEMA_KEY)
    result_days = int(config.get("days_back", DEFAULT_PAST_RESULT_DAYS))
    now = time.now().in_location(tz)
    team_settings = team_settings_by_id[team_id]
    if not team_settings:
        return DEFAULT_SCREEN
    team_api_resp = get_cachable_data(TEAM_HOME_URL + team_settings.objectId, TEAM_HOME_API_CACHE_TTL)
    team_data = json.decode(team_api_resp)
    fixtures = team_data.get("content", {}).get("recentFixtures", [])
    results = team_data.get("content", {}).get("recentResults", [])

    current_match, past_match, next_match = None, None, None
    for fixture in fixtures:
        if fixture["format"] not in ["TEST", "T20", "ODI"]:
            continue
        if str(fixture["teams"][0]["team"]["id"]) not in team_settings_by_id:
            continue
        if str(fixture["teams"][1]["team"]["id"]) not in team_settings_by_id:
            continue
        if fixture["state"] == "LIVE":
            current_match = fixture
        else:
            next_match = fixture
        break
    for result in results:
        if result["format"] not in ["TEST", "T20", "ODI"]:
            continue
        if str(result["teams"][0]["team"]["id"]) not in team_settings_by_id:
            continue
        if str(result["teams"][1]["team"]["id"]) not in team_settings_by_id:
            continue
        past_match = result
        break

    match_to_render, render_fn = None, None
    if current_match:
        match_to_render, render_fn = current_match, render_current_match

    if past_match and not match_to_render:
        match_time = time.parse_time(past_match["endDate"], TIME_FORMAT).in_location(tz)
        result_days_duration = time.parse_duration("{}h".format(result_days * 24))
        if match_time + result_days_duration >= now:
            match_to_render, render_fn = past_match, render_past_match

    if next_match and not match_to_render:
        if fixture_days == ALWAYS_SHOW_FIXTURES_SCHEMA_KEY:
            match_to_render, render_fn = next_match, render_next_match
        else:
            match_time = time.parse_time(next_match["startTime"], TIME_FORMAT).in_location(tz)
            fixture_days_duration = time.parse_duration("{}h".format(int(fixture_days) * 24))
            if now > match_time - fixture_days_duration:
                match_to_render, render_fn = next_match, render_next_match

    if not match_to_render:
        return []
    series_id, match_id = match_to_render["series"]["objectId"], match_to_render["objectId"]
    print("match_id: {} series_id: {}, at {}".format(match_id, series_id, now))

    # past match result
    match_api_resp = get_cachable_data(MATCH_URL.format(series_id = series_id, match_id = match_id), MATCH_API_CACHE_TTL)
    match_data = json.decode(match_api_resp)
    return render_fn(match_data, tz)

def render_current_match(match_data, tz):
    print(tz)
    if match_data["match"]["format"] == "TEST":
        return render_current_test_match(match_data)
    else:
        return render_current_limited_ov_match(match_data)

def render_current_test_match(match_data):
    live_inning = match_data["match"]["liveInning"]
    team_1_id, team_2_id = "", ""
    team_1_abbr, team_2_abbr = "", ""
    team_1_score, team_1_wickets, team_1_overs = 0, 0, 0
    team_2_score, team_2_wickets, team_2_overs = 0, 0, 0
    for tm in match_data["match"]["teams"]:
        if tm["inningNumbers"] and live_inning in tm["inningNumbers"]:
            team_1_id = tm["team"]["id"]
            team_1_abbr = tm["team"]["abbreviation"]
            team_1_score = tm["score"]
        else:
            team_2_id = tm["team"]["id"]
            team_2_abbr = tm["team"]["abbreviation"]
            team_2_score = tm["score"] or 0

    bat_1_name, bat_2_name = "", ""
    bat_1_runs, bat_2_runs = 0, 0
    ing = match_data["scorecard"]["innings"][live_inning - 1]
    for bat in match_data["livePerformance"]["batsmen"]:
        if not bat_1_name:
            bat_1_name = bat["player"]["longName"]
            bat_1_runs = bat["runs"]
        elif not bat_2_name:
            bat_2_name = bat["player"]["longName"]
            bat_2_runs = bat["runs"]

    if not bat_2_name:
        bat_2_name = ing["inningWickets"][-1]["player"]["longName"]
        bat_2_runs = ing["inningWickets"][-1].get("runs", 0)

    team_1_settings = team_settings_by_id[str(team_1_id)]
    team_2_settings = team_settings_by_id[str(team_2_id)]
    row_team_1 = render_team_score_row(team_1_abbr, team_1_score, team_1_wickets, team_1_overs, team_1_settings.fg_color, team_1_settings.bg_color)
    row_team_2 = render_team_score_row(team_2_abbr, team_2_score, team_2_wickets, team_2_overs, team_2_settings.fg_color, team_2_settings.bg_color)
    row_bat_1 = render_batsmen_row(bat_1_name, bat_1_runs, 0, team_1_settings.fg_color)
    row_bat_2 = render_batsmen_row(bat_2_name, bat_2_runs, 0, team_1_settings.fg_color)
    statuses = ["", "", "", ""]
    if match_data["match"]["liveOversPending"] and int(match_data["match"]["liveOversPending"]) > 0:
        statuses[1] = "Overs Rem: {}".format(match_data["match"]["liveOversPending"])
    match_status = match_data["match"]["status"]
    if "stumps" in match_status.lower():
        status_data = match_data["match"]["statusData"]["statusTextLangData"]
        match_status = "Stumps - Day {}".format(status_data["day"])

    # fill remaining status rows
    for i in range(len(statuses)):
        if not statuses[i]:
            statuses[i] = match_status

    status_rows = [render_status_row(s) for s in statuses]
    render_columns = []
    for status_row in status_rows:
        render_columns.append(
            render.Column(
                children = [
                    row_team_1,
                    row_bat_1,
                    row_bat_2,
                    row_team_2,
                    status_row,
                ],
            ),
        )
    return render.Root(
        delay = int(4000),
        child = render.Animation(
            children = render_columns,
        ),
    )

def render_current_limited_ov_match(match_data):
    team_1_id, team_2_id = "", ""
    team_1_abbr, team_2_abbr = "", ""
    team_1_score, team_1_wickets, team_1_overs = 0, 0, 0
    team_2_score, team_2_wickets, team_2_overs = 0, 0, 0

    last_wkt = {}

    # match teams to live innings
    live_inning = match_data["match"]["liveInning"]
    for tm in match_data["match"]["teams"]:
        if tm["inningNumbers"] and tm["inningNumbers"][0] == live_inning:
            team_1_id = tm["team"]["id"]
            team_1_abbr = tm["team"]["abbreviation"]
        else:
            team_2_id = tm["team"]["id"]
            team_2_abbr = tm["team"]["abbreviation"]
    for ing in match_data["scorecard"]["innings"]:
        if ing["inningNumber"] == live_inning:
            team_1_score = ing["runs"]
            team_1_wickets = ing["wickets"]
            team_1_overs = ing["overs"]
            last_wkt = ing["inningWickets"][-1]
        elif live_inning == 2:
            team_2_score = ing["runs"]
            team_2_wickets = ing["wickets"]
            team_2_overs = ing["overs"]
    team_1_settings = team_settings_by_id[str(team_1_id)]
    team_2_settings = team_settings_by_id[str(team_2_id)]
    row_team_1 = render_team_score_row(team_1_abbr, team_1_score, team_1_wickets, team_1_overs, team_1_settings.fg_color, team_1_settings.bg_color)
    row_team_2 = render_team_score_row(team_2_abbr, team_2_score, team_2_wickets, team_2_overs, team_2_settings.fg_color, team_2_settings.bg_color)

    live_bat = match_data["livePerformance"]["batsmen"]
    bat_1_name = live_bat[0]["player"]["longName"]
    bat_1_runs = live_bat[0].get("runs", 0)
    bat_1_balls = live_bat[0].get("balls", 0)
    if len(live_bat) >= 2:
        bat_2_name = live_bat[1]["player"]["longName"]
        bat_2_runs = live_bat[1].get("runs", 0)
        bat_2_balls = live_bat[1].get("balls", 0)
    else:
        bat_2_name = last_wkt["player"]["longName"]
        bat_2_runs = last_wkt.get("runs", 0)
        bat_2_balls = last_wkt.get("balls", 0)

    row_bat_1 = render_batsmen_row(bat_1_name, bat_1_runs, bat_1_balls, team_1_settings.fg_color)
    row_bat_2 = render_batsmen_row(bat_2_name, bat_2_runs, bat_2_balls, team_1_settings.fg_color)
    last_6_balls = []
    for ball in match_data["recentBallCommentary"]["ballComments"][:6]:
        if ball["isWicket"]:
            last_6_balls.append("W")
        elif ball["isSix"]:
            last_6_balls.append("6")
        elif ball["isFour"] == 1:
            last_6_balls.append("4")
        elif ball["byes"] > 0:
            last_6_balls.append("{}b".format(ball["byes"]))
        elif ball["legbyes"] > 0:
            last_6_balls.append("{}lb".format(ball["legbyes"]))
        elif ball["wides"] > 0:
            last_6_balls.append("{}wd".format(ball["wides"]))
        elif ball["noballs"] > 0:
            last_6_balls.append("{}nb".format(ball["noballs"]))
        else:
            last_6_balls.append("{}".format(ball["totalRuns"]))
    status_row_last_6 = render_status_row(" ".join(last_6_balls))
    status_rows = [status_row_last_6] * 4

    match_status_data = match_data["match"]["statusData"]["statusTextLangData"]
    if live_inning == 2:
        need_runs = match_status_data["requiredRuns"]
        if match_status_data["remainingOvers"]:
            rem = match_status_data["remainingOvers"]
        else:
            rem = match_status_data["remainingBalls"]
        reqd_runs_status = "{} runs in {}".format(need_runs, rem)
        reqd_rate_status = "Reqd Rate: {}".format(match_status_data["rrr"])
        status_rows[0] = render_status_row(reqd_runs_status)
        status_rows[1] = render_status_row(reqd_rate_status)
        status_rows[2] = render_status_row(reqd_runs_status)
        status_rows[3] = render_status_row(reqd_rate_status)
    else:
        current_rate_status = "Run Rate: {}".format(match_status_data["crr"])
        status_rows[1] = render_status_row(current_rate_status)
        status_rows[3] = render_status_row(current_rate_status)

    return render.Root(
        delay = int(4000),
        child = render.Animation(
            children = [
                render.Column(
                    children = [
                        row_team_1,
                        row_bat_1,
                        row_bat_2,
                        row_team_2,
                        status_rows[0],
                    ],
                ),
                render.Column(
                    children = [
                        row_team_1,
                        row_bat_1,
                        row_bat_2,
                        row_team_2,
                        status_rows[1],
                    ],
                ),
                render.Column(
                    children = [
                        row_team_1,
                        row_bat_1,
                        row_bat_2,
                        row_team_2,
                        status_rows[2],
                    ],
                ),
                render.Column(
                    children = [
                        row_team_1,
                        row_bat_1,
                        row_bat_2,
                        row_team_2,
                        status_rows[3],
                    ],
                ),
            ],
        ),
    )

def render_next_match(match_data, tz):
    match = match_data["match"]
    team_1_id, team_1_name = match["teams"][0]["team"]["id"], match["teams"][0]["team"]["name"]
    team_2_id, team_2_name = match["teams"][1]["team"]["id"], match["teams"][1]["team"]["name"]

    team_1_settings = team_settings_by_id[str(team_1_id)]
    team_2_settings = team_settings_by_id[str(team_2_id)]

    match_start_time = time.parse_time(match["startTime"], TIME_FORMAT).in_location(tz)
    match_time_status = match_start_time.format("Jan 2 3:04 PM")
    match_title_status = match["title"]
    match_venue_status = match["ground"]["town"]["name"]
    if len(match_venue_status) < 12:
        match_venue_status = "{}, {}".format(match_venue_status, match["ground"]["country"]["abbreviation"])

    team_1_row = render_team_row(team_1_name, team_1_settings.fg_color, team_1_settings.bg_color)
    vs_row = render.Row(
        main_align = "center",
        expanded = True,
        children = [
            render.Box(height = 9, child = render.Text(content = "vs", color = WHITE_COLOR, font = SML_FONT)),
        ],
    )
    team_2_row = render_team_row(team_2_name, team_2_settings.fg_color, team_2_settings.bg_color)
    match_time_status_row = render_status_row(match_time_status)
    match_venue_status_row = render_status_row(match_venue_status)
    match_title_status_row = render_status_row(match_title_status)
    return render.Root(
        delay = int(4000),
        child = render.Animation(
            children = [
                render.Column(
                    children = [
                        team_1_row,
                        vs_row,
                        team_2_row,
                        match_title_status_row,
                    ],
                ),
                render.Column(
                    children = [
                        team_1_row,
                        vs_row,
                        team_2_row,
                        match_time_status_row,
                    ],
                ),
                render.Column(
                    children = [
                        team_1_row,
                        vs_row,
                        team_2_row,
                        match_time_status_row,
                    ],
                ),
                render.Column(
                    children = [
                        team_1_row,
                        vs_row,
                        team_2_row,
                        match_venue_status_row,
                    ],
                ),
            ],
        ),
    )

def render_past_match(match, tz):
    if match["match"]["format"] == "TEST":
        return render_past_test_match(match, tz)
    else:
        return render_past_limited_ov_match(match, tz)

def render_past_test_match(match, tz):
    match_start = time.parse_time(match["match"]["startDate"], TIME_FORMAT).in_location(tz)
    match_dt_status = match_start.format("Jan 2 2006")

    # find team who batted first
    team_1_id, team_2_id = "", ""
    team_1_abbr, team_2_abbr = "", ""
    team_1_score, team_2_score = "", ""
    for tm in match["match"]["teams"]:
        if tm["inningNumbers"] and tm["inningNumbers"][0] == 1:
            team_1_id = tm["team"]["id"]
            team_1_abbr = tm["team"]["abbreviation"]
            team_1_score = tm["score"]
        else:
            team_2_id = tm["team"]["id"]
            team_2_abbr = tm["team"]["abbreviation"]
            team_2_score = tm["score"]

    team_1_settings = team_settings_by_id[str(team_1_id)]
    team_2_settings = team_settings_by_id[str(team_2_id)]

    status_data = match["match"]["statusData"]
    if status_data["statusTextLangData"]["winnerTeamId"] == team_1_id:
        match_result_status = "{} by".format(team_1_abbr)
    elif status_data["statusTextLangData"]["winnerTeamId"] == team_2_id:
        match_result_status = "{} by".format(team_2_abbr)
    else:
        match_result_status = "Match drawn"  # todo: find alternate statuses

    if "runs" in status_data["statusTextLangKey"]:
        match_result_status = "{} {} runs".format(match_result_status, status_data["statusTextLangData"]["wonByRuns"])
    elif "wickets" in status_data["statusTextLangKey"]:
        match_result_status = "{} {} wkts".format(match_result_status, status_data["statusTextLangData"]["wonByWickets"])
    else:
        return DEFAULT_SCREEN

    # find top batsmen and top bowler from last innings
    last_inn = match["scorecardSummary"]["innings"][-1]
    last_inn_bat_name, last_inn_bowl_name = "", ""
    last_inn_bat_runs, last_inn_bowl_runs, last_inn_bowl_overs, last_inn_bowl_wickets = 0, 0, 0, 0

    for batter in last_inn["inningBatsmen"]:
        if not last_inn_bat_name or batter["runs"] > last_inn_bat_runs:
            last_inn_bat_name = batter["player"]["longName"]
            last_inn_bat_runs = batter["runs"]
    for bowler in last_inn["inningBowlers"]:
        if not last_inn_bowl_name or bowler["wickets"] > last_inn_bowl_wickets or (bowler["wickets"] == last_inn_bowl_wickets and bowler["conceded"] < last_inn_bowl_runs):
            last_inn_bowl_name = bowler["player"]["longName"]
            last_inn_bowl_overs = bowler["overs"]
            last_inn_bowl_runs = bowler["conceded"]
            last_inn_bowl_wickets = bowler["wickets"]

    if last_inn["team"]["id"] == team_2_id:
        team_1_player_row = render_bowler_row(last_inn_bowl_name, last_inn_bowl_overs, last_inn_bowl_runs, last_inn_bowl_wickets, team_1_settings.fg_color)
        team_2_player_row = render_batsmen_row(last_inn_bat_name, last_inn_bat_runs, 0, team_2_settings.fg_color)
    else:
        team_1_player_row = render_batsmen_row(last_inn_bat_name, last_inn_bat_runs, 0, team_1_settings.fg_color)
        team_2_player_row = render_bowler_row(last_inn_bowl_name, last_inn_bowl_overs, last_inn_bowl_runs, last_inn_bowl_wickets, team_2_settings.fg_color)

    team_1_score_row = render_team_score_row(team_1_abbr, team_1_score, 0, 0, team_1_settings.fg_color, team_1_settings.bg_color)
    team_2_score_row = render_team_score_row(team_2_abbr, team_2_score, 0, 0, team_2_settings.fg_color, team_2_settings.bg_color)
    match_dt_status_row = render_status_row(match_dt_status)
    match_result_status_row = render_status_row(match_result_status)

    return render.Root(
        delay = int(4000),
        child = render.Animation(
            children = [
                render.Column(
                    children = [
                        team_1_score_row,
                        team_1_player_row,
                        team_2_score_row,
                        team_2_player_row,
                        match_result_status_row,
                    ],
                ),
                render.Column(
                    children = [
                        team_1_score_row,
                        team_1_player_row,
                        team_2_score_row,
                        team_2_player_row,
                        match_result_status_row,
                    ],
                ),
                render.Column(
                    children = [
                        team_1_score_row,
                        team_1_player_row,
                        team_2_score_row,
                        team_2_player_row,
                        match_dt_status_row,
                    ],
                ),
                render.Column(
                    children = [
                        team_1_score_row,
                        team_1_player_row,
                        team_2_score_row,
                        team_2_player_row,
                        match_result_status_row,
                    ],
                ),
            ],
        ),
    )

def render_past_limited_ov_match(match, tz):
    match_start = time.parse_time(match["match"]["startDate"], TIME_FORMAT).in_location(tz)
    match_dt_status = match_start.format("Jan 2 2006")

    team_1_id, team_2_id = "", ""
    team_1_abbr, team_2_abbr = "", ""
    team_1_score, team_1_wickets, team_1_overs = 0, 0, 0
    team_2_score, team_2_wickets, team_2_overs = 0, 0, 0

    # find top batsmen from both teams
    bat_1_name, bat_2_name = "", ""
    bat_1_runs, bat_2_runs = 0, 0
    bat_1_balls, bat_2_balls = 0, 0

    # find top bowler from both teams
    bowl_1_name, bowl_2_name = "", ""
    bowl_1_overs, bowl_2_overs = 0, 0
    bowl_1_runs, bowl_2_runs = 0, 0
    bowl_1_wickets, bowl_2_wickets = 0, 0

    for ing in match["scorecardSummary"]["innings"]:
        if ing["inningNumber"] == 1:
            team_1_id = ing["team"]["id"]
            team_1_abbr = ing["team"]["abbreviation"]
            team_1_score = ing["runs"]
            team_1_wickets = ing["wickets"]
            team_1_overs = ing["overs"]
            for batter in ing["inningBatsmen"]:
                if not bat_1_name or batter["runs"] > bat_1_runs:
                    bat_1_name = batter["player"]["longName"]
                    bat_1_runs = batter["runs"]
                    bat_1_balls = batter["balls"]
            for bowler in ing["inningBowlers"]:
                if not bowl_2_name or bowler["wickets"] > bowl_2_wickets or (bowler["wickets"] == bowl_2_wickets and bowler["conceded"] < bowl_2_runs):
                    bowl_2_name = bowler["player"]["longName"]
                    bowl_2_overs = bowler["overs"]
                    bowl_2_runs = bowler["conceded"]
                    bowl_2_wickets = bowler["wickets"]
        if ing["inningNumber"] == 2:
            team_2_id = ing["team"]["id"]
            team_2_abbr = ing["team"]["abbreviation"]
            team_2_score = ing["runs"]
            team_2_wickets = ing["wickets"]
            team_2_overs = ing["overs"]
            for batter in ing["inningBatsmen"]:
                if not bat_2_name or batter["runs"] > bat_2_runs:
                    bat_2_name = batter["player"]["longName"]
                    bat_2_runs = batter["runs"]
                    bat_2_balls = batter["balls"]
            for bowler in ing["inningBowlers"]:
                if not bowl_1_name or bowler["wickets"] > bowl_1_wickets or (bowler["wickets"] == bowl_1_wickets and bowler["conceded"] < bowl_1_runs):
                    bowl_1_name = bowler["player"]["longName"]
                    bowl_1_overs = bowler["overs"]
                    bowl_1_runs = bowler["conceded"]
                    bowl_1_wickets = bowler["wickets"]

    status_data = match["match"]["statusData"]
    if status_data["statusTextLangData"]["winnerTeamId"] == team_1_id:
        match_result_status = "{} by".format(team_1_abbr)
    elif status_data["statusTextLangData"]["winnerTeamId"] == team_2_id:
        match_result_status = "{} by".format(team_2_abbr)
    else:
        match_result_status = "Match tied"  # just skip a tied match for now

    if "runs" in status_data["statusTextLangKey"]:
        match_result_status = "{} {} runs".format(match_result_status, status_data["statusTextLangData"]["wonByRuns"])
    elif "wickets" in status_data["statusTextLangKey"]:
        match_result_status = "{} {} wkts".format(match_result_status, status_data["statusTextLangData"]["wonByWickets"])

    team_1_settings = team_settings_by_id[str(team_1_id)]
    team_2_settings = team_settings_by_id[str(team_2_id)]

    team_1_score_row = render_team_score_row(team_1_abbr, team_1_score, team_1_wickets, team_1_overs, team_1_settings.fg_color, team_1_settings.bg_color)
    team_1_bat_row = render_batsmen_row(bat_1_name, bat_1_runs, bat_1_balls, team_1_settings.fg_color)
    team_1_bowl_row = render_bowler_row(bowl_1_name, bowl_1_overs, bowl_1_runs, bowl_1_wickets, team_1_settings.fg_color)
    team_2_score_row = render_team_score_row(team_2_abbr, team_2_score, team_2_wickets, team_2_overs, team_2_settings.fg_color, team_2_settings.bg_color)
    team_2_bat_row = render_batsmen_row(bat_2_name, bat_2_runs, bat_2_balls, team_2_settings.fg_color)
    team_2_bowl_row = render_bowler_row(bowl_2_name, bowl_2_overs, bowl_2_runs, bowl_2_wickets, team_2_settings.fg_color)
    return render.Root(
        delay = int(4000),
        child = render.Animation(
            children = [
                render.Column(
                    children = [
                        team_1_score_row,
                        team_1_bat_row,
                        team_2_score_row,
                        team_2_bowl_row,
                        render_status_row(match_result_status),
                    ],
                ),
                render.Column(
                    children = [
                        team_1_score_row,
                        team_1_bat_row,
                        team_2_score_row,
                        team_2_bowl_row,
                        render_status_row(match_result_status),
                    ],
                ),
                render.Column(
                    children = [
                        team_1_score_row,
                        team_1_bowl_row,
                        team_2_score_row,
                        team_2_bat_row,
                        render_status_row(match_dt_status),
                    ],
                ),
                render.Column(
                    children = [
                        team_1_score_row,
                        team_1_bowl_row,
                        team_2_score_row,
                        team_2_bat_row,
                        render_status_row(match_result_status),
                    ],
                ),
            ],
        ),
    )

def render_team_score_row(abbr, score, wickets, overs, fg_color, bg_color):
    wkt_display, over_display = "", ""
    if overs:
        over_display = " {}".format(overs)
    if overs and wickets != 10:
        wkt_display = "/{}".format(wickets)

    if not score and not wickets:
        score_display = "-"
    else:
        score_display = "{}{}{}".format(score, wkt_display, over_display)

    split_score = score_display.split(" & ")
    for i in range(len(split_score)):
        split_score[i] = split_score[i].strip("d").strip("D")
    score_columns = [
        render.Text(content = split_score[0], color = fg_color, font = SML_FONT),
    ]
    if len(split_score) == 2:
        score_columns.append(render.Padding(
            pad = (2, 0, 2, 0),
            child = render.Text(content = "&", color = fg_color, font = SML_FONT),
        ))
        score_columns.append(render.Text(content = split_score[1], color = fg_color, font = SML_FONT))

    rendered_display = render.Box(
        height = 7,
        color = bg_color,
        child = render.Padding(
            pad = (1, 0, 0, 0),
            child = render.Row(
                expanded = True,
                main_align = "space_between",
                children = [
                    render.Row(
                        children = [render.Text(content = abbr, color = fg_color, font = LRG_FONT)],
                    ),
                    render.Row(
                        children = score_columns,
                    ),
                ],
            ),
        ),
    )

    return rendered_display

def render_batsmen_row(name, runs, balls, fg_color = WHITE_COLOR, bg_color = ""):
    left_text = reduce_player_name(name)
    balls_text = "({})".format(balls) if balls else ""
    right_text = "{}{}".format(runs, balls_text)
    return render_player_row(left_text, right_text, fg_color, bg_color)

def render_bowler_row(name, overs, runs, wickets, fg_color = WHITE_COLOR, bg_color = ""):
    left_text = reduce_player_name(name)

    # remove decimal from overs
    overs = str(overs).split(".")[0] if overs > 10 else str(overs)
    right_text = "{}-{}-{}".format(overs, runs, wickets)
    return render_player_row(left_text, right_text, fg_color, bg_color)

def render_player_row(left_text, right_text, fg_color, bg_color):
    return render.Box(
        height = 6,
        color = bg_color,
        child = render.Padding(
            pad = (1, 0, 0, 0),
            child = render.Row(
                expanded = True,
                main_align = "space_between",
                children = [
                    render.Column(
                        cross_align = "start",
                        children = [render.Text(content = left_text, color = fg_color, font = "tom-thumb")],
                    ),
                    render.Column(
                        cross_align = "end",
                        children = [render.Text(content = right_text, color = fg_color, font = SML_FONT)],
                    ),
                ],
            ),
        ),
    )

def render_team_row(name, fg_color, bg_color):
    name = name.upper()
    return render.Box(
        height = 8,
        color = bg_color,
        child = render.Row(
            expanded = True,
            main_align = "center",
            children = [
                render.Text(content = name, color = fg_color, font = "tb-8"),
            ],
        ),
    )

def render_status_row(text, fg_color = WHITE_COLOR, bg_color = BLACK_COLOR):
    text_split = text.split(" ")
    content_columns = []
    for s in text_split:
        content_columns.append(
            render.Padding(
                pad = (1, 0, 1, 0),
                child = render.Text(content = s, color = fg_color, font = SML_FONT),
            ),
        )

    return render.Padding(
        pad = (0, 1, 0, 0),
        child = render.Box(
            height = 5,
            color = bg_color,
            child = render.Row(
                main_align = "center",
                expanded = True,
                children = content_columns,
            ),
        ),
    )

def reduce_player_name(name):
    first, last = name.split(" ")[0], name.split(" ")[-1]
    display = first[0] + "." + last
    if len(display) <= 8:
        return display
    else:
        return last[:8]

def _team_setting(id, objId, name, abbr, fg_color, bg_color):
    return {
        "id": str(id),
        "objectId": objId,
        "name": name,
        "abbr": abbr,
        "fg_color": fg_color,
        "bg_color": bg_color,
    }

team_england = struct(**_team_setting("1", "1", "England", "ENG", "#FFFFFF", "#CE1124"))
team_australia = struct(**_team_setting("2", "2", "Australia", "AUS", "#FFCE00", "#006A4A"))
team_south_africa = struct(**_team_setting("3", "3", "South Africa", "SA", "#FFB81C", "#007749"))
team_west_indies = struct(**_team_setting("4", "4", "West Indies", "WI", "#f2b10e", "#660000"))
team_new_zealand = struct(**_team_setting("5", "5", "New Zealand", "NZ", "#FFFFFF", "#008080"))
team_india = struct(**_team_setting("6", "6", "India", "IND", "#FFFFFF", "#050CEB"))
team_pakistan = struct(**_team_setting("7", "7", "Pakistan", "PAK", "#FFFFFF", "#115740"))
team_sri_lanka = struct(**_team_setting("8", "8", "Sri Lanka", "SL", "#EB7400", "#0A2351"))
team_zimbabwe = struct(**_team_setting("9", "9", "Zimbabwe", "ZIM", "#FCE300", "#EF3340"))
team_usa = struct(**_team_setting("11", "11", "USA", "USA", "#B31942", "#003087"))
team_netherlands = struct(**_team_setting("15", "15", "Netherlands", "NED", "#FFFFFF", "#FF4F00"))
team_bangladesh = struct(**_team_setting("25", "25", "Bangladesh", "BAN", "#F42A41", "#006A4E"))
team_ireland = struct(**_team_setting("29", "29", "Ireland", "IRE", "#169B62", "#FF883E"))
team_scotland = struct(**_team_setting("30", "30", "Scotland", "SCO", "#FFFFFF", "#005EB8"))
team_afghanistan = struct(**_team_setting("40", "40", "Afghanistan", "AFG", "#D32011", BLACK_COLOR))

team_settings_by_id = {
    ts.id: ts
    for ts in [
        team_afghanistan,
        team_australia,
        team_bangladesh,
        team_england,
        team_india,
        team_ireland,
        team_netherlands,
        team_new_zealand,
        team_pakistan,
        team_scotland,
        team_sri_lanka,
        team_south_africa,
        team_usa,
        team_west_indies,
        team_zimbabwe,
    ]
}

team_list_schema_options = [schema.Option(display = ts.name, value = ts.id) for ts in team_settings_by_id.values()]
past_results_day_options = [
    schema.Option(
        display = "1",
        value = "1",
    ),
    schema.Option(
        display = "2",
        value = "2",
    ),
    schema.Option(
        display = "3",
        value = "3",
    ),
    schema.Option(
        display = "5",
        value = "5",
    ),
    schema.Option(
        display = "7",
        value = "7",
    ),
]
upcoming_fixtures_day_options = [
    schema.Option(
        display = "1",
        value = "1",
    ),
    schema.Option(
        display = "2",
        value = "2",
    ),
    schema.Option(
        display = "3",
        value = "3",
    ),
    schema.Option(
        display = "5",
        value = "5",
    ),
    schema.Option(
        display = "7",
        value = "7",
    ),
    schema.Option(
        display = ALWAYS_SHOW_FIXTURES_SCHEMA_KEY,
        value = ALWAYS_SHOW_FIXTURES_SCHEMA_KEY,
    ),
]

def get_schema():
    return schema.Schema(
        version = "1",
        fields = [
            schema.Dropdown(
                id = "team",
                name = "Team",
                desc = "Choose your team",
                icon = "tag",
                default = team_list_schema_options[1].value,
                options = team_list_schema_options,
            ),
            schema.Dropdown(
                id = "days_back",
                name = "# of days back to show scores",
                desc = "Number of days back to search for scores",
                icon = "arrowLeft",
                default = "1",
                options = past_results_day_options,
            ),
            schema.Dropdown(
                id = "days_forward",
                name = "# of days forward to show fixtures",
                desc = "Number of days forward to search for fixtures",
                icon = "arrowRight",
                default = ALWAYS_SHOW_FIXTURES_SCHEMA_KEY,
                options = upcoming_fixtures_day_options,
            ),
        ],
    )

def get_cachable_data(url, timeout):
    res = http.get(url = url, ttl_seconds = timeout)

    if res.status_code != 200:
        fail("request to %s failed with status code: %d - %s" % (url, res.status_code, res.body()))

    return res.body()
