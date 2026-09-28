import { Body, Controller, Get, Param, ParseIntPipe, Post } from '@nestjs/common';
import { JoinQueueDto } from './dto/join-queue.dto.js';
import { ReceiveBookDto } from './dto/receive-book.dto.js';
import { QueueService } from './queue.service.js';

@Controller('queue')
export class QueueController {
  constructor(private readonly queueService: QueueService) {}

  @Post()
  join(@Body() dto: JoinQueueDto) {
    return this.queueService.joinQueue(dto.userId, dto.bookId);
  }

 
 @Post('receive') 
 receive(@Body() dto: ReceiveBookDto) {
  return this.queueService.receiveBook(dto.queueId, dto.userId);
 }

 
  @Get('book/:bookId')
  getForBook(@Param('bookId', ParseIntPipe) bookId: number) {
    return this.queueService.getQueueForBook(bookId);
  }

  @Post(':id/cancel')
  cancel(@Param('id', ParseIntPipe) id: number, @Body('userId', ParseIntPipe) userId: number) {
    return this.queueService.cancelQueueEntry(id, userId);
  }
}