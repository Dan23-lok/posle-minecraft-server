import unittest

from tools.join_country_counts import join_counts


class JoinCountryCountsTests(unittest.TestCase):
    def setUp(self):
        self.geonames = [
            {
                "code": "AA", "name_en": "A", "name_ru": "А",
                "source_settlement_count": "12",
                "wup_2025_urban_centre_count": "",
                "wup_count_status": "NOT_IMPORTED",
                "minecraft_terrain_status": "NOT_GENERATED_IN_CANONICAL_WORLD",
                "minecraft_spawn_status": "NOT_VALIDATED",
            },
            {
                "code": "BB", "name_en": "B", "name_ru": "Б",
                "source_settlement_count": "25",
                "wup_2025_urban_centre_count": "",
                "wup_count_status": "NOT_IMPORTED",
                "minecraft_terrain_status": "NOT_GENERATED_IN_CANONICAL_WORLD",
                "minecraft_spawn_status": "NOT_VALIDATED",
            },
        ]
        self.wup = [
            {"iso2": "BB", "wup_urban_centres_2025": "0", "observed_in_wup_city_rows_2025": "false"},
            {"iso2": "AA", "wup_urban_centres_2025": "3", "observed_in_wup_city_rows_2025": "true"},
        ]

    def test_join_preserves_game_status_and_zero(self):
        rows = join_counts(self.geonames, self.wup, expected_rows=2)
        self.assertEqual([r["code"] for r in rows], ["AA", "BB"])
        self.assertEqual([r["wup_2025_urban_centre_count"] for r in rows], ["3", "0"])
        self.assertEqual([r["wup_city_rows_observed"] for r in rows], ["true", "false"])
        self.assertTrue(all(r["minecraft_terrain_status"] == "NOT_GENERATED_IN_CANONICAL_WORLD" for r in rows))

    def test_missing_or_extra_iso_rejected(self):
        with self.assertRaisesRegex(ValueError, "ISO set mismatch"):
            join_counts(self.geonames, self.wup[:1], expected_rows=2)

    def test_duplicate_or_inconsistent_observation_rejected(self):
        with self.assertRaisesRegex(ValueError, "duplicate"):
            join_counts(self.geonames, self.wup + self.wup[:1], expected_rows=2)
        wrong = [dict(self.wup[0], wup_urban_centres_2025="2"), self.wup[1]]
        with self.assertRaisesRegex(ValueError, "observation"):
            join_counts(self.geonames, wrong, expected_rows=2)


if __name__ == "__main__":
    unittest.main()
