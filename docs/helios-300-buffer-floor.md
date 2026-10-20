# .300 candidate: persistent 16-MiB LINEAR display backing

KMD-created row-major standard display surfaces and the non-dedicated LINEAR
scanout fallback now use **16 MiB (16,777,216 bytes) as their minimum allocation**.
The rule is permanent in source, rather than a temporary setting or cache budget.

The actual Vulkan requirement still wins when larger. The fallback's page
alignment uses checked arithmetic and rejects zero/overflow. Vulkan allocation,
HOST3D blob size and the owned-resource ledger receive the same actual size;
no file-descriptor metadata is inflated without allocating the memory.
`SdgLReq` reports the fallback requirement and `SdgLAlc` the allocated bytes
(the latter is a 32-bit diagnostic, like the existing requirement field).

This does not resize existing imported DMA-BUFs, alter strides/modifiers,
change application texture allocations or inflate dedicated OPTIMAL images.
Dedicated Vulkan allocations retain their image-specific size contract. The
new floor therefore does not promise to repair the previous OPTIMAL import
shape mismatch or the DWM flicker. These still need matching-layout diagnosis.

Existing reuse and completion-before-free rules remain. Old buffers are not
kept forever after resize or device teardown; their replacement obeys the same
minimum. Four 16-MiB buffers require at least 64 MiB, before other driver/runtime
allocations. A 4K image can legitimately require more than 16 MiB per buffer.

The .300 installer must be built and explicitly installed to change guest
allocations. Merely pulling Git or changing a QEMU budget will not update an
installed .291/.299 driver. The bundled .291 installer remains unchanged.
224 dependency-free KMD logic tests pass, including 720p/1080p-size requirements,
requests over 16 MiB, 4K-size backing and overflow. Physical Windows/NVIDIA
validation is pending; a successful build is not a flicker fix certification.
