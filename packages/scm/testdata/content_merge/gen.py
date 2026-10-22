# Regenerates content_merge_git.txt: 200 random three-way merges and git
# merge-file's diff3 output for each (git 2.43 was used). Each case is
# "case", then base, ours and theirs as "<length>\n<bytes>", then
# "clean|conflict <length>\n<output>". Tests need only the .txt file.
import random, subprocess, os, tempfile
random.seed(704)
words = ["a","b","c","d","e","f","g","h"]
def rand_lines(n): return [random.choice(words)+"\n" for _ in range(n)]
def mutate(lines):
    l = list(lines)
    for _ in range(random.randint(1,2)):
        op = random.choice(["mod","del","ins"])
        if op=="mod" and l:
            i=random.randrange(len(l)); l[i]=random.choice(words).upper()+"\n"
        elif op=="del" and l:
            i=random.randrange(len(l)); del l[i]
        else:
            i=random.randint(0,len(l)); l.insert(i, random.choice(words)+str(random.randint(0,9))+"\n")
    return l
out=[]
d=tempfile.mkdtemp()
for k in range(200):
    base=rand_lines(random.randint(3,10))
    left=mutate(base); right=mutate(base)
    files={}
    for name,ls in (("base",base),("left",left),("right",right)):
        p=os.path.join(d,name); open(p,"w").write("".join(ls)); files[name]=p
    r=subprocess.run(["git","merge-file","-p","--diff3","-L","ours","-L","base","-L","theirs",files["left"],files["base"],files["right"]],capture_output=True,text=True)
    rec="case\n"
    for ls in (base,left,right):
        s="".join(ls); rec+=f"{len(s)}\n{s}"
    rec+=f"{'clean' if r.returncode==0 else 'conflict'} {len(r.stdout)}\n{r.stdout}"
    out.append(rec)
open(os.path.join(os.path.dirname(os.path.abspath(__file__)),"content_merge_git.txt"),"w").write("".join(out))
print(sum(1 for o in out if "clean " in o), "clean of", len(out))
