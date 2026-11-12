# Brainmelt
kumolii/brainmelt | my low quality brainfuck interpreter
## Building
Requirements:
 - Linux
 - Git
 - Luvi
 - Luvit
 - SDL2 (if you wanna use the display)
 
 Instructions:
```
git clone kumolii/brainmelt
cd brainmelt
chmod +x *.sh
./build.sh # Note: this will install brainmelt to /usr/bin/brainmelt and also output it to ./dist
```
You could probably do it manually, but I personally don't think it would be a good idea.
## Usage

    brainmelt [options] [file]

If you want to pass input, use `[input] | brainmelt [options] [file]`

If you want to pass a string as the file, use ```[brainfuck code] | brainmelt [options] -```

Note: if you want vanilla brainfuck, just don't pass any options
### Command Line Options

 - -m, -\-memsize | Default: 30,000 | Amount of cells brainfuck can use (looping)
 - -d, --display | Enables the display.
 - -t, --test | Uses a embedded test instead of a file.
- -w, --width | Default: 30 | Width of the display, does nothing if -d flag isn't present.
- -h, --height | Default: 30 | Height of the display.
- -s, --size | Default: 10 | Scale of the display.
- -c, --color | Default: g | The color type the display can use. g=grayscale, r=rgb, p=palette
- -f, --maxfps | Default: 30 | Max FPS of the display.
- -a, --audio | Enables audio.
- -l, --soundLength | Default: 10 | How many cells are reserved for audio

Note: Cells for display are reserved BEFORE cells for audio. So by default, the first 900 cells are reserved for display, and the 10 cells AFTER that are reserved for audio. Enabling rgb triples the display cell reservation count.
## Why?
got bored and decided i wanted to make a brainfuck interpreter with video support

it can also play bad apple lol

https://x.com/KumoliiPaws/status/2120687770901299569
