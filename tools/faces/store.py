import os
import sqlite3

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "work")
CROPS = os.path.join(WORK, "crops")

SCHEMA = """
CREATE TABLE IF NOT EXISTS photo (
  key TEXT PRIMARY KEY, local_id TEXT, etag TEXT, w INTEGER, h INTEGER,
  error TEXT, analysed_at INTEGER);
CREATE TABLE IF NOT EXISTS face (
  id INTEGER PRIMARY KEY, key TEXT NOT NULL,
  x REAL, y REAL, w REAL, h REAL, score REAL, size REAL, blur REAL, yaw REAL,
  vec BLOB NOT NULL);
CREATE INDEX IF NOT EXISTS face_key ON face(key);
CREATE TABLE IF NOT EXISTS label (
  face_id INTEGER PRIMARY KEY, person TEXT, source TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS cluster (
  face_id INTEGER PRIMARY KEY, cluster INTEGER, suggested TEXT, sim REAL);
CREATE TABLE IF NOT EXISTS suspect (
  face_id INTEGER PRIMARY KEY, person TEXT, sim REAL);
"""


def connect():
    os.makedirs(CROPS, exist_ok=True)
    db = sqlite3.connect(os.path.join(WORK, "faces.db"), timeout=60)
    db.execute("PRAGMA journal_mode=WAL")  # review/cluster write while analyse runs
    db.executescript(SCHEMA)
    return db


def to_blob(v):
    return np.asarray(v, dtype=np.float32).tobytes()


def from_blob(b):
    return np.frombuffer(b, dtype=np.float32)
