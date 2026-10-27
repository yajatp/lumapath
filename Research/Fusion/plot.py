#!/usr/bin/env python3
"""Render the held-out reliability diagram; requires the pinned plotting dependency."""
import json
import sys
from pathlib import Path
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
root=Path(sys.argv[1]); report=json.loads((root/'metrics.json').read_text())
fig,ax=plt.subplots(figsize=(6,5),layout='constrained')
ax.plot([0,1],[0,1],color='gray',linestyle='--',label='Perfect calibration')
for key,label in [('baseline','Deterministic'),('learned','Calibrated logistic')]:
    bins=[b for b in report[key]['calibration'] if b['count']]
    ax.plot([b['meanProbability'] for b in bins],[b['positiveRate'] for b in bins],marker='o',label=label)
ax.set(xlim=(0,1),ylim=(0,1),xlabel='Mean predicted support',ylabel='Observed support rate',
       title='Synthetic pipeline check' if report['synthetic'] else 'Held-out semantic support')
ax.legend(); fig.savefig(root/'calibration.png',dpi=160)
