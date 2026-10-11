import unittest

from tools.export_country_settlement_counts import build_rows


class CountrySettlementExportTests(unittest.TestCase):
    def setUp(self):
        self.countries = [
            {"iso2": "RU", "name_en": "Russia", "name_ru": "Россия", "un_status": "member_state", "m49_broad_region": "Europe"},
            {"iso2": "VA", "name_en": "Holy See", "name_ru": "Святой Престол", "un_status": "observer_state", "m49_broad_region": "Europe"},
        ]
        self.areas = [{"code": "AW", "name_en": "Aruba", "name_ru": "Аруба", "catalog_kind": "iso_area_outside_195"}]
        self.counts = [
            {"country_code": "RU", "feature_code": "PPL", "populated_place_source_records": "2"},
            {"country_code": "RU", "feature_code": "PPLC", "populated_place_source_records": "1"},
            {"country_code": "RU", "feature_code": "PPLX", "populated_place_source_records": "50"},
            {"country_code": "AW", "feature_code": "PPLA", "populated_place_source_records": "4"},
            {"country_code": "ZZ", "feature_code": "PPL", "populated_place_source_records": "3"},
        ]

    def test_source_code_filter_and_country_area_separation(self):
        countries, areas, summary = build_rows(self.countries, self.areas, self.counts)
        self.assertEqual(countries[0]["source_settlement_count"], 3)
        self.assertEqual(countries[1]["source_settlement_count"], 0)
        self.assertEqual(countries[1]["source_count_status"], "OBSERVED_ZERO_IN_SOURCE")
        self.assertEqual(countries[0]["wup_2025_urban_centre_count"], "")
        self.assertEqual(countries[0]["wup_count_status"], "NOT_IMPORTED")
        self.assertEqual(countries[0]["minecraft_terrain_status"], "NOT_GENERATED_IN_CANONICAL_WORLD")
        self.assertEqual(areas[0]["source_settlement_count"], 4)
        self.assertEqual(summary["selected_source_rows"], 10)
        self.assertEqual(summary["baseline_rows"], 3)
        self.assertEqual(summary["area_rows"], 4)
        self.assertEqual(summary["other_or_unassigned_rows"], 3)
        self.assertEqual(summary["other_by_code"], {"ZZ": 3})

    def test_duplicate_iso_code_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "duplicate baseline code"):
            build_rows(self.countries + [dict(self.countries[0])], self.areas, self.counts)


if __name__ == "__main__":
    unittest.main()
