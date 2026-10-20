//! D3D11 subresource cardinality limits, before allocation or pointer traversal.
//! Zero mip/array values retain the existing one-element normalization.
pub(crate) fn subresource_count(mips: u32, array: u32) -> Option<usize> {
    // D3D11_REQ_MIP_LEVELS=15, D3D11_REQ_TEXTURE2D_ARRAY_AXIS_DIMENSION=2048.
    if mips > 15 || array > 2048 { return None; }
    (mips.max(1) as usize).checked_mul(array.max(1) as usize)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cardinality_is_bounded_before_multiply() {
        assert_eq!(subresource_count(0, 0), Some(1));
        assert_eq!(subresource_count(15, 2048), Some(30720));
        for (m, a) in [(16, 1), (1, 2049), (u32::MAX, u32::MAX)] {
            assert_eq!(subresource_count(m, a), None);
        }
    }
}
