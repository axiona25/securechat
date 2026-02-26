from rest_framework.pagination import PageNumberPagination
from rest_framework.response import Response


class AdminPagination(PageNumberPagination):
    """
    Pagination compatible with React-Admin.
    Supports: ?page=1&page_size=25
    Returns: Content-Range header for React-Admin.
    """
    page_size = 25
    page_size_query_param = 'page_size'
    max_page_size = 100

    def get_paginated_response(self, data):
        count = self.page.paginator.count
        response = Response(data)
        # Content-Range header for React-Admin compatibility
        start = (self.page.number - 1) * self.get_page_size(self.request)
        end = start + len(data) - 1
        response['Content-Range'] = f'items {start}-{end}/{count}'
        response['X-Total-Count'] = str(count)
        # Also include in body for convenience
        response.data = {
            'results': data,
            'count': count,
            'page': self.page.number,
            'page_size': self.get_page_size(self.request),
            'total_pages': self.page.paginator.num_pages,
        }
        return response
