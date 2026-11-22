import zlib
ref = zlib.decompress("image/file_example_PNG_500kB.png")   # len(ref) debería ser 1443300

print(len(ref))
print(next((i for i,(a,b) in enumerate(zip(ref)) if a!=b), None))