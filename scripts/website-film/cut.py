"""Cuts the website film (img/film.mp4, its poster) and the pop-up clips
(img/clips/*.mp4 and their posters) from a recording made by record.sh, and
prints where each chapter starts in the film, for FILM_CHAPTERS in index.html.

    python3 scripts/website-film/cut.py
"""
import json, os, subprocess

R = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))) + '/'
F = '/tmp/coinpurse-film/'
os.makedirs(F + 'cut', exist_ok=True)
start = float(open(F + 'rec_start.txt').read())
t = {line.split()[0]: float(line.split()[1]) - start for line in open(F + 'chapters.txt')}

# The film's chapters, in order, and how much faster each plays than it was recorded.
order = ['purse', 'snap', 'say', 'pin', 'open', 'directions', 'back', 'peek', 'move', 'tickets', 'find', 'share', 'hide', 'toss']
speed = {'purse': 1, 'snap': 1.3, 'say': 1.4, 'pin': 1.9, 'open': 1.2, 'directions': 1.3, 'back': 1, 'peek': 1,
         'move': 1, 'tickets': 1.4, 'find': 1.4, 'share': 2.0, 'hide': 1.3, 'toss': 0.9}
following = {name: t[(order + ['end'])[i + 1]] for i, name in enumerate(order)}

def cut(a, b, sp, out, width, crf='27'):
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', f'{a:.2f}', '-to', f'{b:.2f}', '-i', F + 'cfr.mp4',
                    '-vf', f'setpts=PTS/{sp},fps=30,scale={width}:-2', '-an', '-c:v', 'libx264', '-crf', crf,
                    '-preset', 'slow', '-pix_fmt', 'yuv420p', '-r', '30', out], check=True)

starts, pos, files = [], 0.0, []
for name in order:
    a, b, sp = t[name], following[name], speed[name]
    out = F + f'cut/{name}.mp4'
    cut(a, b, sp, out, 590)
    files.append(out)
    starts.append((name, round(pos, 2)))
    pos += (b - a) / sp
open(F + 'cut/list.txt', 'w').write(''.join(f"file '{f}'\n" for f in files))
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', F + 'cut/list.txt', '-c', 'copy',
                '-movflags', '+faststart', R + 'img/film.mp4'], check=True)
subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', '1.0', '-i', R + 'img/film.mp4', '-frames:v', '1', '-q:v', '4',
                R + 'img/film-poster.jpg'], check=True)

# Each pop-up's clip: from one chapter to another, at its own speed.
clips = {'giftcard': ('snap', 'say', 1.2), 'voice': ('say', 'pin', 1.3), 'parking': ('pin', 'back', 2.0),
         'tickets': ('tickets', 'find', 1.4), 'badge': ('share', 'hide', 2.0), 'taptext': ('x-taptext', 'x-grocery', 1.0),
         'grocery': ('x-grocery', 'x-faceid', 1.0), 'faceid': ('x-faceid', 'x-end', 1.0)}
for name, (a, b, sp) in clips.items():
    out = R + f'img/clips/{name}.mp4'
    cut(t[a], t[b], sp, out, 360, '28')
    subprocess.run(['ffmpeg', '-v', 'error', '-y', '-ss', '0.8', '-i', out, '-frames:v', '1', '-q:v', '5',
                    R + f'img/clips/{name}.jpg'], check=True)

print(json.dumps(starts))
print('film length', round(pos, 1), 's')
