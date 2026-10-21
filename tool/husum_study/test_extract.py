import unittest
from extract import intersects, walkable


class FilteringTests(unittest.TestCase):
    def test_crossing_segment_without_inside_vertex_is_retained(self):
        self.assertTrue(intersects((8.9, 54.48), (9.2, 54.48)))
        self.assertTrue(intersects((9.05, 54.4), (9.05, 54.6)))
        self.assertFalse(intersects((8.9, 54.4), (9.2, 54.4)))
        self.assertTrue(intersects((9.05, 54.48), (9.05, 54.48)))
        self.assertFalse(intersects((8.9, 54.4), (8.9, 54.4)))

    def test_pedestrian_access_and_highway_filters(self):
        self.assertTrue(walkable({'highway': 'footway'}))
        self.assertTrue(walkable({'highway': 'residential', 'access': 'private', 'foot': 'yes'}))
        for tags in [{'highway': 'motorway'}, {'highway': 'path', 'foot': 'no'},
                     {'highway': 'path', 'access': 'private'}, {'building': 'yes'},
                     {'highway': 'pedestrian', 'area': 'yes'}]:
            self.assertFalse(walkable(tags))


if __name__ == '__main__':
    unittest.main()
