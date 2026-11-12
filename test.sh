#!/bin/bash

binary="${BRAINMELT_BINARY:-./dist/brainmelt}"
if [[ "$binary" != /* ]]; then
    binary="$PWD/$binary"
fi

runTest() {
    local name="$1" cmd="$2" expected="$3" is_sha="$4"
    local output start end elapsed
    
    start=$(date +%s.%N)
    
    if [ -n "$is_sha" ]; then
        output=$(eval "$cmd" | sha256sum | awk '{print $1}')
    else
        output=$(eval "$cmd")
    fi
    
    end=$(date +%s.%N)
    elapsed=$(awk "BEGIN {printf \"%.3f\", $end - $start}")

    if [ "$output" = "$expected" ]; then
        echo "  $name (${elapsed}s)"
    else
        echo "  $name (${elapsed}s)"
    fi
}

echo "Source:"
runTest "cat" "echo 'test123' | luvit main.lua ./tests/cat.bf" "test123"
runTest "Hello World" "luvit main.lua ./tests/helloworld.bf" "Hello World!"
runTest "Twinkle" "luvit main.lua ./tests/twinkle.bf" "d10dc4feace54a4c3b15aeeda613e3a4377c53d0266f4eacb362ca100bb954b8" sha
runTest "Slow Test" "luvit main.lua ./tests/slowTest.bf" "fc099771419c6d5dcdd4c3b0e9acb477d88d18b77579c7d147666660039bbb86" sha
runTest "Slower Test" "luvit main.lua ./tests/bigTest.bf" "b05e3dde6c811e65b5ccf47bb0669f901075d8f2800dc95a771113abb0a157c4" sha
echo "Binary:"
runTest "cat" "echo 'test123' | \"$binary\" ./tests/cat.bf" "test123"
runTest "Hello World" "\"$binary\" ./tests/helloworld.bf" "Hello World!"
runTest "outside working directory" "cd /tmp && \"$binary\" \"$PWD/tests/helloworld.bf\"" "Hello World!"
runTest "Twinkle" "\"$binary\" ./tests/twinkle.bf" "d10dc4feace54a4c3b15aeeda613e3a4377c53d0266f4eacb362ca100bb954b8" sha
runTest "Slow Test" "\"$binary\" ./tests/slowTest.bf" "fc099771419c6d5dcdd4c3b0e9acb477d88d18b77579c7d147666660039bbb86" sha
runTest "Slower Test" "\"$binary\" ./tests/bigTest.bf" "b05e3dde6c811e65b5ccf47bb0669f901075d8f2800dc95a771113abb0a157c4" sha