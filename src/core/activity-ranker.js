function rankProjects(projects, now = new Date()) {
  return [...projects]
    .map((project, index) => ({
      ...project,
      score: scoreProject(project, now),
      _rankIndex: index
    }))
    .sort((a, b) => {
      if (b.score !== a.score) {
        return b.score - a.score;
      }

      const activityDelta = timestamp(b.lastActivityAt) - timestamp(a.lastActivityAt);
      if (activityDelta !== 0) {
        return activityDelta;
      }

      return a._rankIndex - b._rankIndex;
    })
    .map(({ _rankIndex, ...project }) => project);
}

function pickActiveProject(projects, now = new Date()) {
  return rankProjects(projects, now)[0] || null;
}

function scoreProject(project, now = new Date()) {
  const nowMs = now.getTime();
  const activityAge = nowMs - timestamp(project.lastActivityAt);
  const commitAge = nowMs - timestamp(project.lastCommitAt);
  let score = 0;

  if (Number.isFinite(activityAge)) {
    if (activityAge <= 5 * 60 * 1000) {
      score += 100;
    } else if (activityAge <= 30 * 60 * 1000) {
      score += 60;
    }
  }

  if (project.dirty) {
    score += 30;
  }

  if (Number.isFinite(commitAge) && commitAge <= 60 * 60 * 1000) {
    score += 40;
  }

  if (project.branch && !['main', 'master'].includes(project.branch)) {
    score += 10;
  }

  return score;
}

function timestamp(value) {
  if (!value) {
    return Number.NEGATIVE_INFINITY;
  }

  const time = new Date(value).getTime();
  return Number.isNaN(time) ? Number.NEGATIVE_INFINITY : time;
}

module.exports = {
  pickActiveProject,
  rankProjects,
  scoreProject
};
