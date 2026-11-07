from __future__ import annotations

import numpy as np

from ailbum.ranking.features import FEATURE_NAMES, FEATURE_VERSION


class LogisticModel:
    """L2 logistic regression on standardized features; pairwise use fits on (x_a - x_b) with label 1 if a is preferred."""

    def __init__(self, weights, bias, mean, std, feature_version=FEATURE_VERSION, feature_names=FEATURE_NAMES):
        self.weights = np.asarray(weights, dtype=np.float64)
        self.bias = float(bias)
        self.mean = np.asarray(mean, dtype=np.float64)
        self.std = np.asarray(std, dtype=np.float64)
        self.feature_version = int(feature_version)
        self.feature_names = tuple(feature_names)

    @classmethod
    def fit(cls, x: np.ndarray, y: np.ndarray, l2: float = 1.0) -> LogisticModel:
        x = np.asarray(x, dtype=np.float64)
        y = np.asarray(y, dtype=np.float64)
        mean = x.mean(axis=0)
        std = x.std(axis=0)
        std = np.where(std < 1e-12, 1.0, std)
        z = (x - mean) / std
        n, d = z.shape
        a = np.hstack([z, np.ones((n, 1))])
        reg = np.eye(d + 1) * l2
        reg[d, d] = 0.0  # bias is not penalized
        beta = np.zeros(d + 1)
        for _ in range(50):  # Newton steps, deterministic
            p = 1.0 / (1.0 + np.exp(-np.clip(a @ beta, -30, 30)))
            grad = a.T @ (p - y) + reg @ beta
            hess = (a * (p * (1 - p))[:, None]).T @ a + reg + np.eye(d + 1) * 1e-9
            step = np.linalg.solve(hess, grad)
            beta -= step
            if np.max(np.abs(step)) < 1e-8:
                break
        return cls(beta[:d], beta[d], mean, std)

    def score(self, x: np.ndarray) -> np.ndarray:
        z = (np.asarray(x, dtype=np.float64) - self.mean) / self.std
        return 1.0 / (1.0 + np.exp(-np.clip(z @ self.weights + self.bias, -30, 30)))

    def to_json(self) -> dict:
        return {
            "weights": self.weights.tolist(),
            "bias": self.bias,
            "mean": self.mean.tolist(),
            "std": self.std.tolist(),
            "feature_version": self.feature_version,
            "feature_names": list(self.feature_names),
        }

    @classmethod
    def from_json(cls, data: dict) -> LogisticModel:
        return cls(
            data["weights"], data["bias"], data["mean"], data["std"],
            data["feature_version"], data["feature_names"],
        )
